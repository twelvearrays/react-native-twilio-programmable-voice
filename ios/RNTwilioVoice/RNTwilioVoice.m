//
//  TwilioVoice.m
//

#import "RNTwilioVoice.h"
#import <React/RCTLog.h>

@import AVFoundation;
@import PushKit;
@import CallKit;
@import TwilioVoice;

@interface RNTwilioVoice () <PKPushRegistryDelegate, TVONotificationDelegate, TVOCallDelegate, CXProviderDelegate>
@property (nonatomic, strong) NSString *deviceTokenString;

@property (nonatomic, strong) PKPushRegistry *voipRegistry;
@property (nonatomic, strong) void(^incomingPushCompletionCallback)(void);
@property (nonatomic, strong) TVOCallInvite *callInvite;
@property (nonatomic, strong) TVOCall *call;
@property (nonatomic, strong) void(^callKitCompletionCallback)(BOOL);
@property (nonatomic, strong) CXProvider *callKitProvider;
@property (nonatomic, strong) CXCallController *callKitCallController;

//Add
@property (nonatomic, strong) TVODefaultAudioDevice *audioDevice;


@end

@implementation RNTwilioVoice {
    NSMutableDictionary *_settings;
    NSMutableDictionary *_callParams;
    NSString *_tokenUrl;
    NSString *_token;
}

NSString * const StatePending = @"PENDING";
NSString * const StateConnecting = @"CONNECTING";
NSString * const StateConnected = @"CONNECTED";
NSString * const StateDisconnected = @"DISCONNECTED";
NSString * const StateRejected = @"REJECTED";
NSString * const To = @"+19033520328";

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"connectionDidConnect", @"connectionDidDisconnect", @"callRejected", @"deviceReady", @"deviceNotReady"];
}

@synthesize bridge = _bridge;

- (void)dealloc {
    if (self.callKitProvider) {
        [self.callKitProvider invalidate];
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

RCT_EXPORT_METHOD(initWithAccessToken:(NSString *)token) {
    _token = token;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppTerminateNotification) name:UIApplicationWillTerminateNotification object:nil];
    [self initPushRegistry];
}

RCT_EXPORT_METHOD(initWithAccessTokenUrl:(NSString *)tokenUrl) {
    _tokenUrl = tokenUrl;
    NSLog(@"Twilio - initWithAccessTokenUrl %@", _tokenUrl);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppTerminateNotification) name:UIApplicationWillTerminateNotification object:nil];
    [self initPushRegistry];
}

RCT_EXPORT_METHOD(configureCallKit: (NSDictionary *)params) {
    //No changes
    if (self.callKitCallController == nil) {
        _settings = [[NSMutableDictionary alloc] initWithDictionary:params];
        CXProviderConfiguration *configuration = [[CXProviderConfiguration alloc] initWithLocalizedName:params[@"appName"]];
        configuration.maximumCallGroups = 1;
        configuration.maximumCallsPerCallGroup = 1;
        if (_settings[@"imageName"]) {
            configuration.iconTemplateImageData = UIImagePNGRepresentation([UIImage imageNamed:_settings[@"imageName"]]);
        }
        if (_settings[@"ringtoneSound"]) {
            configuration.ringtoneSound = _settings[@"ringtoneSound"];
        }
        
        _callKitProvider = [[CXProvider alloc] initWithConfiguration:configuration];
        [_callKitProvider setDelegate:self queue:nil];
        
        NSLog(@"Twilio - CallKit Initialized");
        
        self.callKitCallController = [[CXCallController alloc] init];
    }
}

RCT_EXPORT_METHOD(connect: (NSDictionary *)params) {
    NSLog(@"Twilio - Calling phone number %@", [params valueForKey:@"To"]);
    
    //[TwilioVoice setLogLevel:TVOLogLevelDebug];
    
    UIDevice* device = [UIDevice currentDevice];
    device.proximityMonitoringEnabled = YES;
    
    if (self.call && self.call.state == TVOCallStateConnected) {
        [self.call disconnect];
    } else {
        NSUUID *uuid = [NSUUID UUID];
        NSString *handle = [params valueForKey:@"To"];
        _callParams = [[NSMutableDictionary alloc] initWithDictionary:params];
        [self performStartCallActionWithUUID:uuid handle:handle];
    }
}

RCT_EXPORT_METHOD(disconnect) {
    NSLog(@"Twilio - Disconnecting call");
    [self performEndCallActionWithUUID:self.call.uuid];
}

RCT_EXPORT_METHOD(setMuted: (BOOL *)muted) {
    NSLog(@"Twilio - Mute/UnMute call");
    self.call.muted = muted;
}

RCT_EXPORT_METHOD(setSpeakerPhone: (BOOL *)speaker) {
    [self toggleAudioRoute:speaker];
}

RCT_EXPORT_METHOD(sendDigits: (NSString *)digits){
    if (self.call && self.call.state == TVOCallStateConnected) {
        NSLog(@"Twilio - SendDigits %@", digits);
        [self.call sendDigits:digits];
    }
}

RCT_EXPORT_METHOD(unregister){
    NSLog(@"Twilio - unregister");
    NSString *accessToken = [self fetchAccessToken];
    
    [TwilioVoice unregisterWithAccessToken:accessToken
                               deviceToken:self.deviceTokenString
                                completion:^(NSError * _Nullable error) {
                                    if (error) {
                                        NSLog(@"Twilio - An error occurred while unregistering: %@", [error localizedDescription]);
                                    } else {
                                        NSLog(@"Twilio - Successfully unregistered for VoIP push notifications.");
                                    }
                                }];
    
    self.deviceTokenString = nil;
}

RCT_REMAP_METHOD(getActiveCall,
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    if (self.callInvite) {
        if (self.callInvite.callSid){
            [params setObject:self.callInvite.callSid forKey:@"call_sid"];
        }
        if (self.callInvite.from){
            [params setObject:self.callInvite.from forKey:@"from"];
        }
        if (self.callInvite.to){
            [params setObject:self.callInvite.to forKey:@"to"];
        }
        // No callInvite state
        //    if (self.callInvite.state == TVOCallInviteStatePending) {
        //      [params setObject:StatePending forKey:@"call_state"];
        //    } else if (self.callInvite.state == TVOCallInviteStateCanceled) {
        //      [params setObject:StateDisconnected forKey:@"call_state"];
        //    } else if (self.callInvite.state == TVOCallInviteStateRejected) {
        //      [params setObject:StateRejected forKey:@"call_state"];
        //    }
        resolve(params);
    } else if (self.call) {
        if (self.call.sid) {
            [params setObject:self.call.sid forKey:@"call_sid"];
        }
        if (self.call.to){
            [params setObject:self.call.to forKey:@"call_to"];
        }
        if (self.call.from){
            [params setObject:self.call.from forKey:@"call_from"];
        }
        if (self.call.state == TVOCallStateConnected) {
            [params setObject:StateConnected forKey:@"call_state"];
        } else if (self.call.state == TVOCallStateConnecting) {
            [params setObject:StateConnecting forKey:@"call_state"];
        } else if (self.call.state == TVOCallStateDisconnected) {
            [params setObject:StateDisconnected forKey:@"call_state"];
        }
        resolve(params);
    } else{
        reject(@"no_call", @"There was no active call", nil);
    }
}

- (void)initPushRegistry {
    self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.voipRegistry.delegate = self;
    self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
    
    self.audioDevice = [TVODefaultAudioDevice audioDevice];
    TwilioVoice.audioDevice = self.audioDevice;
    
}

- (NSString *)fetchAccessToken {
    //No Changes
    NSLog(@"Twilio - Calling phone number %@", _tokenUrl);
    if (_tokenUrl) {
        NSString *accessToken = [NSString stringWithContentsOfURL:[NSURL URLWithString:_tokenUrl]
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
        return accessToken;
    } else {
        return _token;
    }
}

#pragma mark - PKPushRegistryDelegate
- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type {
    NSLog(@"Twilio - pushRegistry:didUpdatePushCredentials:forType");
    
    if ([type isEqualToString:PKPushTypeVoIP]) {
        
        //self.deviceTokenString = [credentials.token description];
        // NSString *accessToken = [self fetchAccessToken];
        
        const unsigned *tokenBytes = [credentials.token bytes];
        self.deviceTokenString = [NSString stringWithFormat:@"<%08x %08x %08x %08x %08x %08x %08x %08x>",
                                  ntohl(tokenBytes[0]), ntohl(tokenBytes[1]), ntohl(tokenBytes[2]),
                                  ntohl(tokenBytes[3]), ntohl(tokenBytes[4]), ntohl(tokenBytes[5]),
                                  ntohl(tokenBytes[6]), ntohl(tokenBytes[7])];
        NSString *accessToken = [self fetchAccessToken];
        
        
        
        [TwilioVoice registerWithAccessToken:accessToken
                                 deviceToken:self.deviceTokenString
                                  completion:^(NSError *error) {
                                      if (error) {
                                          NSLog(@"Twilio - An error occurred while registering: %@", [error localizedDescription]);
                                          NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
                                          [params setObject:[error localizedDescription] forKey:@"err"];
                                          
                                          [self sendEventWithName:@"deviceNotReady" body:params];
                                      } else {
                                          NSLog(@"Twilio - Successfully registered for VoIP push notifications.");
                                          [self sendEventWithName:@"deviceReady" body:nil];
                                      }
                                  }];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    NSLog(@"Twilio - pushRegistry:didInvalidatePushTokenForType");
    
    if ([type isEqualToString:PKPushTypeVoIP]) {
        NSString *accessToken = [self fetchAccessToken];
        
        [TwilioVoice unregisterWithAccessToken:accessToken
                                   deviceToken:self.deviceTokenString
                                    completion:^(NSError * _Nullable error) {
                                        if (error) {
                                            NSLog(@"Twilio - An error occurred while unregistering: %@", [error localizedDescription]);
                                        } else {
                                            NSLog(@"Twilio - Successfully unregistered for VoIP push notifications.");
                                        }
                                    }];
        
        self.deviceTokenString = nil;
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry
didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(NSString *)type
withCompletionHandler:(void (^)(void))completion {
    NSLog(@"Twilio - pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:");
    
    // FROM Migration Docs
    if ([payload.dictionaryPayload[@"twi_message_type"] isEqualToString:@"twilio.voice.cancel"]) {

        NSLog(@"Twilio - FAKE CALL ");
        CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypePhoneNumber value:@"alice"];

        CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
        callUpdate.remoteHandle = callHandle;
        callUpdate.supportsDTMF = YES;
        callUpdate.supportsHolding = YES;
        callUpdate.supportsGrouping = NO;
        callUpdate.supportsUngrouping = NO;
        callUpdate.hasVideo = NO;

        NSUUID *uuid = [NSUUID UUID];

        [self.callKitProvider reportNewIncomingCallWithUUID:uuid update:callUpdate completion:^(NSError *error) {

        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
            CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];

            [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {

            }];
        });

        return;
    }
    //
    
    
    // Save for later when the notification is properly handled.
    self.incomingPushCompletionCallback = completion;
    
    
    // if ([type isEqualToString:PKPushTypeVoIP]) {
    //   [TwilioVoice handleNotification:payload.dictionaryPayload
    //                                           delegate:self];
    // }
    
    if ([type isEqualToString:PKPushTypeVoIP]) {
        // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error` when delegate queue is not passed
        if (![TwilioVoice handleNotification:payload.dictionaryPayload delegate:self delegateQueue:nil]) {
            NSLog(@"Twilio - This is not a valid Twilio Voice notification.");
        }
    }
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
        // Save for later when the notification is properly handled.
        self.incomingPushCompletionCallback = completion;
    } else {
        /**
         * The Voice SDK processes the call notification and returns the call invite synchronously. Report the incoming call to
         * CallKit and fulfill the completion before exiting this callback method.
         */
        completion();
    }
}

//Add
- (void)incomingPushHandled {
    if (self.incomingPushCompletionCallback) {
        self.incomingPushCompletionCallback();
        self.incomingPushCompletionCallback = nil;
    }
}

//Add
- (void)cancelledCallInviteReceived:(TVOCancelledCallInvite *)cancelledCallInvite error:(NSError *)error {
    
    /**
     * The SDK may call `[TVONotificationDelegate callInviteReceived:error:]` asynchronously on the dispatch queue
     * with a `TVOCancelledCallInvite` if the caller hangs up or the client encounters any other error before the called
     * party could answer or reject the call.
     */
    
    NSLog(@"Twilio - cancelledCallInviteReceived:");
    
    if (!self.callInvite ||
        ![self.callInvite.callSid isEqualToString:cancelledCallInvite.callSid]) {
        NSLog(@"Twilio - No matching pending CallInvite. Ignoring the Cancelled CallInvite");
        return;
    }
    
    [self performEndCallActionWithUUID:self.callInvite.uuid];
    
    self.callInvite = nil;
}

#pragma mark - TVONotificationDelegate
- (void)callInviteReceived:(TVOCallInvite *)callInvite {
    
    /**
     * Calling `[TwilioVoice handleNotification:delegate:]` will synchronously process your notification payload and
     * provide you a `TVOCallInvite` object. Report the incoming call to CallKit upon receiving this callback.
     */
    
    NSLog(@"Twilio - callInviteReceived:");
    
    //    if (callInvite.state == TVOCallInviteStatePending) {
    //      [self handleCallInviteReceived:callInvite];
    //    } else if (callInvite.state == TVOCallInviteStateCanceled) {
    //      [self handleCallInviteCanceled:callInvite];
    //    }
    //TODO: return this to React Native
    if (self.callInvite) {
        NSLog(@"Twilio - A CallInvite is already in progress. Ignoring the incoming CallInvite from %@", callInvite.from);
        if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
            [self incomingPushHandled];
        }
        return;
    } else if (self.call) {
        NSLog(@"Twilio - Already an active call. Ignoring the incoming CallInvite from %@", callInvite.from);
        if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
            [self incomingPushHandled];
        }
        return;
    }
    
    self.callInvite = callInvite;
    
    NSString *from = @"Twilio - Voice Bot";
    if (callInvite.from) {
        from = [callInvite.from stringByReplacingOccurrencesOfString:@"client:" withString:@""];
    }
    
    [self reportIncomingCallFrom:from withUUID:callInvite.uuid];
}

// Removed and replaced with incomingPushHandled
//- (void)handleCallInviteReceived:(TVOCallInvite *)callInvite {
//  NSLog(@"callInviteReceived:");
//  if (self.callInvite && self.callInvite == TVOCallInviteStatePending) {
//    NSLog(@"Already a pending incoming call invite.");
//    NSLog(@"  >> Ignoring call from %@", callInvite.from);
//    return;
//  } else if (self.call) {
//    NSLog(@"Already an active call.");
//    NSLog(@"  >> Ignoring call from %@", callInvite.from);
//    return;
//  }
//
//  self.callInvite = callInvite;
//
//  [self reportIncomingCallFrom:callInvite.from withUUID:callInvite.uuid];
//}

- (void)handleCallInviteCanceled:(TVOCallInvite *)callInvite {
    NSLog(@"Twilio - callInviteCanceled");
    
    [self performEndCallActionWithUUID:callInvite.uuid];
    
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    if (self.callInvite.callSid){
        [params setObject:self.callInvite.callSid forKey:@"call_sid"];
    }
    
    if (self.callInvite.from){
        [params setObject:self.callInvite.from forKey:@"from"];
    }
    if (self.callInvite.to){
        [params setObject:self.callInvite.to forKey:@"to"];
    }
    //  if (self.callInvite.state == TVOCancelledCallInvite) {
    //    [params setObject:StateDisconnected forKey:@"call_state"];
    //  } else if (self.callInvite.state == TVOCallInviteStateRejected) {
    //    [params setObject:StateRejected forKey:@"call_state"];
    //  }
    [self sendEventWithName:@"connectionDidDisconnect" body:params];
    
    self.callInvite = nil;
}

- (void)notificationError:(NSError *)error {
    NSLog(@"Twilio - notificationError: %@", [error localizedDescription]);
}

#pragma mark - TVOCallDelegate
- (void)callDidConnect:(TVOCall *)call {
    self.call = call;
    self.callKitCompletionCallback(YES);
    self.callKitCompletionCallback = nil;
    
    NSMutableDictionary *callParams = [[NSMutableDictionary alloc] init];
    [callParams setObject:call.sid forKey:@"call_sid"];
    if (call.state == TVOCallStateConnecting) {
        [callParams setObject:StateConnecting forKey:@"call_state"];
    } else if (call.state == TVOCallStateConnected) {
        [callParams setObject:StateConnected forKey:@"call_state"];
    }
    
    if (call.from){
        [callParams setObject:call.from forKey:@"from"];
    }
    if (call.to){
        [callParams setObject:call.to forKey:@"to"];
    }
    [self sendEventWithName:@"connectionDidConnect" body:callParams];
}

- (void)call:(TVOCall *)call didFailToConnectWithError:(NSError *)error {
    NSLog(@"Twilio - Call failed to connect: %@", error);
    
    self.callKitCompletionCallback(NO);
    [self performEndCallActionWithUUID:call.uuid];
    [self callDisconnected:error];
}

- (void)call:(TVOCall *)call didDisconnectWithError:(NSError *)error {
    NSLog(@"Twilio - Call disconnected with error: %@", error);
    
    [self performEndCallActionWithUUID:call.uuid];
    [self callDisconnected:error];
}

- (void)callDisconnected:(NSError *)error {
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    if (error) {
        NSString* errMsg = [error localizedDescription];
        if (error.localizedFailureReason) {
            errMsg = [error localizedFailureReason];
        }
        [params setObject:errMsg forKey:@"error"];
    }
    if (self.call.sid) {
        [params setObject:self.call.sid forKey:@"call_sid"];
    }
    if (self.call.to){
        [params setObject:self.call.to forKey:@"call_to"];
    }
    if (self.call.from){
        [params setObject:self.call.from forKey:@"call_from"];
    }
    if (self.call.state == TVOCallStateDisconnected) {
        [params setObject:StateDisconnected forKey:@"call_state"];
    }
    [self sendEventWithName:@"connectionDidDisconnect" body:params];
    
    self.call = nil;
    self.callKitCompletionCallback = nil;
}

#pragma mark - AVAudioSession
- (void)toggleAudioRoute: (BOOL *)toSpeaker {
    // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver.
    // Use port override to switch the route.
    NSError *error = nil;
    NSLog(@"Twilio - toggleAudioRoute");
    
    if (toSpeaker) {
        if (![[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                                                error:&error]) {
            NSLog(@"Twilio - Unable to reroute audio: %@", [error localizedDescription]);
        }
    } else {
        if (![[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone
                                                                error:&error]) {
            NSLog(@"Twilio - Unable to reroute audio: %@", [error localizedDescription]);
        }
    }
}

#pragma mark - CXProviderDelegate
- (void)providerDidReset:(CXProvider *)provider {
    NSLog(@"Twilio - providerDidReset");
    //TwilioVoice.audioEnabled = YES;
    self.audioDevice.enabled = YES;
    
}

- (void)providerDidBegin:(CXProvider *)provider {
    NSLog(@"Twilio - providerDidBegin");
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    NSLog(@"Twilio - provider:didActivateAudioSession");
    //  TwilioVoice.audioEnabled = YES;
    self.audioDevice.enabled = YES;
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    NSLog(@"Twilio - provider:didDeactivateAudioSession");
    //  TwilioVoice.audioEnabled = NO;
    self.audioDevice.enabled = NO;
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action {
    NSLog(@"Twilio - provider:timedOutPerformingAction");
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
    NSLog(@"Twilio - provider:performStartCallAction");
    
    //  [TwilioVoice configureAudioSession];
    //  TwilioVoice.audioEnabled = NO;
    self.audioDevice.enabled = NO;
    self.audioDevice.block();
    
    [self.callKitProvider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:[NSDate date]];
    
    __weak typeof(self) weakSelf = self;
    [self performVoiceCallWithUUID:action.callUUID client:nil completion:^(BOOL success) {
        __strong typeof(self) strongSelf = weakSelf;
        if (success) {
            [strongSelf.callKitProvider reportOutgoingCallWithUUID:action.callUUID connectedAtDate:[NSDate date]];
            [action fulfill];
        } else {
            [action fail];
        }
    }];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    NSLog(@"Twilio - provider:performAnswerCallAction");
    
    // RCP: Workaround from https://forums.developer.apple.com/message/169511 suggests configuring audio in the
    //      completion block of the `reportNewIncomingCallWithUUID:update:completion:` method instead of in
    //      `provider:performAnswerCallAction:` per the WWDC examples.
    // [TwilioVoice configureAudioSession];
    
    NSAssert([self.callInvite.uuid isEqual:action.callUUID], @"We only support one Invite at a time.");
    
    //  TwilioVoice.audioEnabled = NO;
    self.audioDevice.enabled = NO;
    [self performAnswerVoiceCallWithUUID:action.callUUID completion:^(BOOL success) {
        if (success) {
            [action fulfill];
        } else {
            [action fail];
        }
    }];
    
    [action fulfill];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    NSLog(@"Twilio - provider:performEndCallAction");
    
    //  TwilioVoice.audioEnabled = NO;
    self.audioDevice.enabled = NO;
    if (self.callInvite && self.call.state == TVOCallStateRinging) {
        [self sendEventWithName:@"callRejected" body:@"callRejected"];
        [self.callInvite reject];
        self.callInvite = nil;
    } else if (self.call) {
        [self.call disconnect];
    }
    
    [action fulfill];
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action {
    if (self.call && self.call.state == TVOCallStateConnected) {
        [self.call setOnHold:action.isOnHold];
        [action fulfill];
    } else {
        [action fail];
    }
}

#pragma mark - CallKit Actions
- (void)performStartCallActionWithUUID:(NSUUID *)uuid handle:(NSString *)handle {
    //No Changes
    NSLog(@"Twilio - uuid: %@", uuid);
    NSLog(@"Twilio - handle: %@", handle);
    if (uuid == nil || handle == nil) {
        return;
    }
    
    CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypePhoneNumber value:handle];
    CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:callHandle];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:startCallAction];
    
    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"Twilio - StartCallAction transaction request failed: %@", [error localizedDescription]);
        } else {
            NSLog(@"Twilio - StartCallAction transaction request successful");
            
            CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
            callUpdate.remoteHandle = callHandle;
            callUpdate.supportsDTMF = YES;
            callUpdate.supportsHolding = YES;
            callUpdate.supportsGrouping = NO;
            callUpdate.supportsUngrouping = NO;
            callUpdate.hasVideo = NO;
            
            [self.callKitProvider reportCallWithUUID:uuid updated:callUpdate];
        }
    }];
}

- (void)performVoiceCallWithUUID:(NSUUID *)uuid
                          client:(NSString *)client
                      completion:(void(^)(BOOL success))completionHandler {
    //Add
    __weak typeof(self) weakSelf = self;
    
    TVOConnectOptions *connectOptions = [TVOConnectOptions optionsWithAccessToken:[self fetchAccessToken] block:^(TVOConnectOptionsBuilder *builder) {
        __strong typeof(self) strongSelf = weakSelf;
        builder.params = _callParams;
        builder.uuid = uuid;
    }];
    self.call = [TwilioVoice connectWithOptions:connectOptions delegate:self];
    //---
    //    self.call = [TwilioVoice call:[self fetchAccessToken]
    //                                            params:_callParams
    //                                              uuid:uuid
    //                                          delegate:self];
    
    self.callKitCompletionCallback = completionHandler;
}

- (void)reportIncomingCallFrom:(NSString *)from withUUID:(NSUUID *)uuid {
    //No Changes
    CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypePhoneNumber value:from];
    
    CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
    callUpdate.remoteHandle = callHandle;
    callUpdate.supportsDTMF = YES;
    callUpdate.supportsHolding = YES;
    callUpdate.supportsGrouping = NO;
    callUpdate.supportsUngrouping = NO;
    callUpdate.hasVideo = NO;
    
    [self.callKitProvider reportNewIncomingCallWithUUID:uuid update:callUpdate completion:^(NSError *error) {
        if (!error) {
            NSLog(@"Twilio - Incoming call successfully reported");
            
            // RCP: Workaround per https://forums.developer.apple.com/message/169511
            //      [TwilioVoice configureAudioSession];
        } else {
            NSLog(@"Twilio - Failed to report incoming call successfully: %@.", [error localizedDescription]);
        }
    }];
}

// Replaced with function below
- (void)performEndCallActionWithUUID:(NSUUID *)uuid {
    if (uuid == nil) {
        return;
    }
    
    UIDevice* device = [UIDevice currentDevice];
    device.proximityMonitoringEnabled = NO;
    
    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];
    
    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"EndCallAction transaction request failed: %@", [error localizedDescription]);
        } else {
            NSLog(@"EndCallAction transaction request successful");
        }
    }];
}

//- (void)performEndCallActionWithUUID:(NSUUID *)uuid {
//    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
//    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];
//
//    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
//        if (error) {
//            NSLog(@"Twilio - EndCallAction transaction request failed: %@", [error localizedDescription]);
//        }
//        else {
//            NSLog(@"Twilio - EndCallAction transaction request successful");
//        }
//    }];
//}



- (void)performAnswerVoiceCallWithUUID:(NSUUID *)uuid
                            completion:(void(^)(BOOL success))completionHandler {
    
    //    self.call = [self.callInvite acceptWithDelegate:self];
    //    self.callInvite = nil;
    //    self.callKitCompletionCallback = completionHandler;
    //Add
    __weak typeof(self) weakSelf = self;
    TVOAcceptOptions *acceptOptions = [TVOAcceptOptions optionsWithCallInvite:self.callInvite block:^(TVOAcceptOptionsBuilder *builder) {
        __strong typeof(self) strongSelf = weakSelf;
        builder.uuid = strongSelf.callInvite.uuid;
    }];
    
    self.call = [self.callInvite acceptWithOptions:acceptOptions delegate:self];
    
    if (!self.call) {
        completionHandler(NO);
    } else {
        self.callKitCompletionCallback = completionHandler;
    }
    
    self.callInvite = nil;
    
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
        [self incomingPushHandled];
    }
    //----
}

- (void)handleAppTerminateNotification {
    NSLog(@"Twilio - handleAppTerminateNotification called");
    
    if (self.call) {
        NSLog(@"Twilio - handleAppTerminateNotification disconnecting an active call");
        [self.call disconnect];
    }
}

@end
