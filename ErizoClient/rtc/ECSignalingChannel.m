//
//  ErizoClientIOS
//
//  Copyright (c) 2015 Alvaro Gil (zevarito@gmail.com).
//
//  MIT License, see LICENSE file for details.
//

#import <Foundation/Foundation.h>

#import "ECSignalingMessage.h"
#import "ECSignalingChannel.h"
#import "ECSignalingEvent.h"
#import "RTCSessionDescription+JSON.h"
#import "Logger.h"
@import SocketIO;

#define ASSERT_STREAM_ID_STRING(streamId) { \
NSAssert([streamId isKindOfClass:[NSString class]], @"streamId needs to be a string");\
}

#define BY_PASS_SELF_SIGN

typedef void(^SocketIOCallback)(NSArray* data);

@interface ECSignalingChannel ()
@end

@implementation ECSignalingChannel {
    SocketIOClient *socketIO;
    BOOL isConnected;
    NSString *encodedToken;
    NSDictionary *decodedToken;
    NSMutableDictionary *outMessagesQueues;
    NSMutableDictionary *streamSignalingDelegates;
    NSDictionary *roomMetadata;
    SocketManager *manager;
    int socketgd;
}

- (instancetype)initWithEncodedToken:(NSString *)token
                        roomDelegate:(id<ECSignalingChannelRoomDelegate>)roomDelegate
                      clientDelegate:(id<ECClientDelegate>)clientDelegate {
    if (self = [super init]) {
        _roomDelegate = roomDelegate;
        encodedToken = token;
        [self decodeToken:token];
    }
    return self;
}

- (void)connect {
    L_INFO(@"Opening Websocket Connection...");
    outMessagesQueues = [NSMutableDictionary dictionary];
    streamSignalingDelegates = [[NSMutableDictionary alloc] init];
    BOOL secure = [(NSNumber *)[decodedToken objectForKey:@"secure"] boolValue];
    NSString *tokenId = (NSString *)[decodedToken objectForKey:@"tokenId"];
    NSString *signature = (NSString *)[decodedToken objectForKey:@"signature"];
    NSString *host = (NSString *)[decodedToken objectForKey:@"host"];
    //    NSString *urlString = [NSString stringWithFormat:@"https://%@/token",
    NSString *urlString = [NSString stringWithFormat:@"https://%@/socket.io/?singlePC=true&tokeId=%@&host=%@&secure=true&signature=%@&EIO=3&transport=websocket",
                           [decodedToken objectForKey:@"host"],tokenId,host,signature];

//wss://t.callt.net:8030/socket.io/?singlePC=true&tokenId=60cb09c741116a1dc8789c42&host=t.callt.net:8030&secure=true&signature=MGI1ZjAwYTYwNTkyYjdmNTg3NGQ3NWY3NWQ5MjFhMTJhOTkyYTc3MQ==&EIO=3&transport=websocket
    NSURL *url = [NSURL URLWithString:urlString];
    L_INFO(@"Opening Websocket Connection... %@",urlString);

//    socketIO = [[SocketIOClient alloc] initWithSocketURL:url
//                                                  config:@{
//														#ifdef DEBUG
//														   @"log":@YES,
//														#else
//															@"log":@NO,
//														#endif
//                                                           @"forcePolling": @NO,
//                                                           @"forceWebsockets": @YES,
//                                                           @"secure": [NSNumber numberWithBool:secure],
//                                                           @"reconnects": @NO,
//														#ifdef BY_PASS_SELF_SIGN
//                                                           @"selfSigned":@YES
//														#endif
//                                                         }];
     manager = [[SocketManager alloc] initWithSocketURL:url config:@{
                                                        #ifdef DEBUG
                                                           @"log":@YES,
                                                        #else
                                                            @"log":@NO,
                                                        #endif
//                                                           @"tokenId":tokenId,
//                                                           @"signature":signature,
//                                                           @"transport":@"websocket",
//                                                           @"EIO":@"3",
//                                                           @"host":host,
                                                           @"singlePC":@YES,
                                                           @"forcePolling": @NO,
                                                           @"forceWebsockets": @YES,
                                                           @"secure": [NSNumber numberWithBool:secure],
                                                           @"reconnects": @NO,
                                                           @"connectParams": decodedToken,
                                                        #ifdef BY_PASS_SELF_SIGN
                                                           @"selfSigned":@YES
                                                        #endif
                                                         }];
    socketIO = manager.defaultSocket;
    
    [socketIO on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
        L_INFO(@"Websocket Connection success!");
        // https://github.com/lynckia/licode/blob/f2e0ccf31d09418c40929b09a3399d1cf7e9a502/erizo_controller/erizoController/models/Channel.js#L64
        NSMutableDictionary *tokenOptions = [NSMutableDictionary dictionaryWithDictionary:
                                             @{@"singlePC": @YES,
                                               @"token": decodedToken}];
        NSArray *dataToSend = [[NSArray alloc] initWithObjects: tokenOptions, nil];
        [[socketIO emitWithAck:@"token" with:dataToSend] timingOutAfter:0 callback:^(NSArray* data) {
            [self onSendTokenCallback](data);
        }];
    }];
    [socketIO on:@"disconnect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        L_WARNING(@"Websocket disconnected: %@", data);
        outMessagesQueues = [NSMutableDictionary dictionary];
        streamSignalingDelegates = [[NSMutableDictionary alloc] init];
        [_roomDelegate signalingChannel:self didDisconnectOfRoom:roomMetadata];
        [socketIO removeAllHandlers];
        socketIO = nil;
    }];
    [socketIO on:@"error" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        L_ERROR(@"Websocket error: %@", data);
        NSString *dataString = [NSString stringWithFormat:@"%@", data];
        [_roomDelegate signalingChannel:self didError:dataString];
    }];
    [socketIO on:@"reconnect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        // TODO
    }];
    [socketIO on:@"reconnectAttempt" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        // TODO
    }];
    [socketIO on:@"statusChange" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        NSLog(@"[WSS]: status change: %@", data);
    }];

    [socketIO on:@"connected" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        NSLog(@"[WSS]: connected: %@", data);
        [self onSendTokenCallback](data);
    }];

    [socketIO on:kEventPublishMe callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketPublishMe:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventOnAddStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketAddStream:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventOnRemoveStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketRemoveStream:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventSignalingMessageErizo callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketSignalingMessage:[data objectAtIndex:0] type:kEventSignalingMessageErizo];
    }];
    [socketIO on:kEventSignalingMessagePeer callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketSignalingMessage:[data objectAtIndex:0] type:kEventSignalingMessagePeer];
    }];
    [socketIO on:kEventOnDataStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketDataStream:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventOnUpdateAttributeStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onUpdateAttributeStream:[data objectAtIndex:0]];
    }];

    [socketIO connect];
}

- (void)disconnect {
    [socketIO disconnect];
}

- (void)enqueueSignalingMessage:(ECSignalingMessage *)message {
	NSString *key =  [self keyForDelegateWithStreamId:message.streamId peerSocketId:message.peerSocketId connectionId:message.connectionId];

    if (message.type == kECSignalingMessageTypeAnswer ||
        message.type == kECSignalingMessageTypeOffer) {
        [[outMessagesQueues objectForKey:key] insertObject:message atIndex:0];
    } else if (message.type == kECSignalingMessageTypeCandidate) {
        [self sendSignalingMessage:message];
    } else {
        [[outMessagesQueues objectForKey:key] addObject:message];
    }
}

/*
 [
     "connectionMessage",
     {
         "socketgd": 27,
         "msg": {
             "options": {
                 "connectionId": "0fe49d0e-e42f-45a2-907d-5324685cde05_c2362747-5181-0756-dbe4-7b433de7c988_3",
                 "erizoId": "c2362747-5181-0756-dbe4-7b433de7c988",
                 "msg": {
                     "type": "candidate",
                     "candidate": {
                         "sdpMLineIndex": -1,
                         "sdpMid": "end",
                         "candidate": "end"
                     }
                 },
                 "browser": "mozilla"
             }
         }
     }
 ]
 */
- (void)sendSignalingMessage:(ECSignalingMessage *)message {
    if (message.erizoId == (id)[NSNull null] ||
        message.connectionId == (id)[NSNull null] ||
        !message.connectionId ||
        [message.connectionId isEqualToString:@""]||
        !message.erizoId ||
        [message.erizoId isEqualToString:@""]) {
        L_WARNING(@"Sending orphan signaling message, lack erizoId or connectionId");
		return;
    }
    
    NSError *error;
    NSDictionary *messageDictionary = [NSJSONSerialization
                                       JSONObjectWithData:[message JSONData]
                                       options:NSJSONReadingMutableContainers error:&error];
    
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
	
	if (message.erizoId){
    	[data setObject:message.erizoId forKey:kEventKeyErizoId];
	}
	if (message.connectionId){
		[data setObject:message.connectionId forKey:kEventKeyConnectionId];
	}
    if (message.peerSocketId) {
        [data setObject:message.peerSocketId forKey:kEventKeyPeerSocketId];
    }
    [data setObject:@"mozilla" forKey:@"browser"];
    [data setObject:messageDictionary forKey:@"msg"];

    NSDictionary *options = @{@"options": data};
    NSDictionary *msg = @{@"msg": options, @"socketgd": @(socketgd)};

    [self sendSocketMessage:[[NSArray alloc] initWithObjects:msg, [NSNull null], nil] type:@"connectionMessage"];
}

- (void)drainMessageQueueForStreamId:(NSString *)streamId peerSocketId:(NSString *)peerSocketId connectionId:(NSString *)connectionId {
    ASSERT_STREAM_ID_STRING(streamId);
	NSString *key =  [self keyForDelegateWithStreamId:streamId peerSocketId:peerSocketId connectionId:connectionId];

    for (ECSignalingMessage *message in [outMessagesQueues objectForKey:key]) {
        [self sendSignalingMessage:message];
    }
    [[outMessagesQueues objectForKey:key] removeAllObjects];
}

- (void)publish:(NSDictionary*)options signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    
    NSMutableDictionary *attributes = [options mutableCopy];
    
    if (!options[@"state"]) {
        attributes[@"state"] = @"erizo";
    }

    attributes[@"encryptTransport"] = @YES;
    attributes[@"handlerProfile"] = [NSNull null];

    NSArray *dataToSend = [[NSArray alloc] initWithObjects: @{@"msg": @{@"options": attributes}, @"socketgd":@(socketgd)}, nil];
    SocketIOCallback callback = [self onPublishCallback:delegate];
    [[self sendACK:dataToSend type:@"publish"] timingOutAfter:10 callback:callback];
}

- (void)unpublish:(NSString *)streamId signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    SocketIOCallback callback = [self onUnPublishCallback:streamId];
    [[socketIO emitWithAck:@"unpublish" with:@[[self longStreamId:streamId]]] timingOutAfter:10
                                                                                    callback:callback];
}

- (void)publishToPeerID:(NSString *)peerSocketId signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    L_INFO(@"Publishing streamId: %@ to peerSocket: %@", delegate.streamId, delegate.peerSocketId);

    // Keep track of an unique delegate for this stream id.
    [self setSignalingDelegate:delegate];

    // Notify room and signaling delegates
    [delegate signalingChannelDidOpenChannel:self];
    [delegate signalingChannel:self readyToPublishStreamId:delegate.streamId peerSocketId:delegate.peerSocketId];
    [_roomDelegate signalingChannel:self didReceiveStreamIdReadyToPublish:delegate.streamId];
}

- (void)subscribe:(NSString *)streamId
    streamOptions:(NSDictionary *)streamOptions
signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    ASSERT_STREAM_ID_STRING(streamId);

    NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithDictionary:streamOptions];
    [attributes setValuesForKeysWithDictionary:@{
                                                 @"browser": @"mozilla",
                                                 @"maxVideoBW": @"300",
                                                 @"encryptTransport": @"true",
                                                 @"metadata": @{@"type":@"subscriber"},
                                                 @"streamId": [self longStreamId:streamId],
                                                 }];

    NSArray *dataToSend = [[NSArray alloc] initWithObjects: @{@"msg": @{@"options": attributes}, @"socketgd":@(socketgd)}, nil];

    SocketIOCallback callback = [self onSubscribeMCUCallback:streamId signalingChannelDelegate:delegate];
    [[self sendACK:dataToSend type:@"subscribe"] timingOutAfter:0 callback:callback];
}

- (void)unsubscribe:(NSString *)streamId {
    ASSERT_STREAM_ID_STRING(streamId);

    SocketIOCallback callback = [self onUnSubscribeCallback:streamId];
    [[socketIO emitWithAck:@"unsubscribe" with:@[[self longStreamId:streamId]]] timingOutAfter:0
                                                                                      callback:callback];
}


- (void)startRecording:(NSString *)streamId {
    ASSERT_STREAM_ID_STRING(streamId);
    NSNumber *longStreamId = [self longStreamId:streamId];
    SocketIOCallback callback = [self onStartRecordingCallback:streamId];
    [[socketIO emitWithAck:@"startRecorder" with:@[@{@"to":longStreamId}]] timingOutAfter:0
                                                                                 callback:callback];
}

- (void)sendDataStream:(ECSignalingMessage *)message {

	if (!message.streamId || [message.streamId isEqualToString:@""]) {
		L_WARNING(@"Sending orphan signaling message, lack streamId");
		return;
	}

	NSError *error;
	NSDictionary *messageDictionary = [NSJSONSerialization JSONObjectWithData:[message JSONData]
                                                                          options:NSJSONReadingMutableContainers
                                                                            error:&error];
	NSMutableDictionary *data = [NSMutableDictionary dictionary];

	[data setObject:@([message.streamId longLongValue]) forKey:@"id"];
	[data setObject:messageDictionary forKey:@"msg"];

	L_INFO(@"Send event message data stream: %@", data);
    [socketIO emit:@"sendDataStream" with:[[NSArray alloc] initWithObjects: data, nil]];
}

- (void)updateStreamAttributes:(ECSignalingMessage *)message {
	
	if (!message.streamId || [message.streamId isEqualToString:@""]) {
		L_WARNING(@"Sending orphan signaling message, lack streamId");
		return;
	}
	
	NSError *error;
	NSDictionary *messageDictionary = [NSJSONSerialization
									   JSONObjectWithData:[message JSONData]
									              options:NSJSONReadingMutableContainers error:&error];
	
	NSMutableDictionary *data = [NSMutableDictionary dictionary];
	
	[data setObject:@([message.streamId longLongValue]) forKey:@"id"];
	[data setObject:messageDictionary forKey:@"attrs"];
	
	L_INFO(@"Update attribute stream: %@", data);
	
	[socketIO emit:@"updateStreamAttributes"
              with:[[NSArray alloc] initWithObjects: data, nil]];
}

#
# pragma mark - ECLicodeProtocol
#

- (void)onSocketPublishMe:(NSDictionary *)msg {
    ECSignalingMessage *message = [ECSignalingMessage messageFromDictionary:msg];
    [_roomDelegate signalingChannel:self
   didRequestPublishP2PStreamWithId:message.streamId
                       peerSocketId:message.peerSocketId];
}

- (void)onSocketAddStream:(NSDictionary *)msg {
    ECSignalingEvent *event = [[ECSignalingEvent alloc] initWithName:kEventOnAddStream
                                                             message:msg];
    NSString *sId = [NSString stringWithFormat:@"%@", [msg objectForKey:@"id"]];
    [_roomDelegate signalingChannel:self didStreamAddedWithId:sId event:event];
}

- (void)onSocketRemoveStream:(NSDictionary *)msg {
    NSString *sId = [NSString stringWithFormat:@"%@", [msg objectForKey:@"id"]];
    [_roomDelegate signalingChannel:self didRemovedStreamId:sId];
}

- (void)onSocketDataStream:(NSDictionary *)msg {
    NSDictionary *dataStream = [msg objectForKey:@"msg"];
    NSString *sId = [NSString stringWithFormat:@"%@", [msg objectForKey:@"id"]];
    if([_roomDelegate respondsToSelector:@selector(signalingChannel:fromStreamId:receivedDataStream:)]) {
        [_roomDelegate signalingChannel:self fromStreamId:sId receivedDataStream:dataStream];
    }
}

- (void)onUpdateAttributeStream:(NSDictionary *)msg {
    //ECSignalingEvent *event = [[ECSignalingEvent alloc] initWithName:kEventOnAddStream
    //                                                         message:msg];
    NSDictionary *attributes = [msg objectForKey:kEventKeyUpdatedAttributes];
    NSString *sId = [NSString stringWithFormat:@"%@", [msg objectForKey:@"id"]];
    if([_roomDelegate respondsToSelector:@selector(signalingChannel:fromStreamId:updateStreamAttributes:)]) {
        [_roomDelegate signalingChannel:self fromStreamId:sId updateStreamAttributes:attributes];
    }
}

- (void)onSocketSignalingMessage:(NSDictionary *)msg type:(NSString *)type {
    ECSignalingMessage *message = [ECSignalingMessage messageFromDictionary:msg];
	NSString *key = nil;
	if (!message.streamId) {
		key = [self startKeyForDelegateWithConnectionId:message.connectionId];
	} else {
		key = [self keyForDelegateWithStreamId:message.streamId
									   peerSocketId:message.peerSocketId
									   connectionId:message.connectionId];
	}

    id<ECSignalingChannelDelegate> signalingDelegate = nil;
	if (!message.streamId) {
		signalingDelegate = [self signalingDelegateForStartKey:key];
	} else {
		signalingDelegate = [self signalingDelegateForKey:key];
	}
    if (!signalingDelegate) {
        signalingDelegate = [_roomDelegate clientDelegateRequiredForSignalingChannel:self];
        [signalingDelegate setStreamId:message.streamId];
        [signalingDelegate setPeerSocketId:message.peerSocketId];
        [self setSignalingDelegate:signalingDelegate];
    }

    [signalingDelegate signalingChannel:self didReceiveMessage:message];
    
    if ([type isEqualToString:kEventSignalingMessagePeer] &&
        message.peerSocketId && message.type == kECSignalingMessageTypeOffer) {
        // FIXME: Looks like in P2P mode subscribe callback isn't called after attempt
        // to subscribe a stream, that's why sometimes signalingDelegate couldn't not yet exits
        [signalingDelegate signalingChannelDidOpenChannel:self];
        [signalingDelegate signalingChannel:self
                   readyToSubscribeStreamId:message.streamId
                               peerSocketId:message.peerSocketId];
    }
}

#
# pragma mark - Callback blocks
#

- (SocketIOCallback)onSubscribeMCUCallback:(NSString *)streamId signalingChannelDelegate:(id<ECSignalingChannelDelegate>)signalingDelegate {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        L_INFO(@"SignalingChannel Subscribe callback: %@", argsData);
        if ((bool)[argsData objectAtIndex:0]) {
            // Keep track of an unique delegate for this stream id and peer socket if p2p.
            signalingDelegate.streamId = streamId;
			signalingDelegate.erizoId = [argsData objectAtIndex:1];
			signalingDelegate.connectionId = [argsData objectAtIndex:2];
            [self setSignalingDelegate:signalingDelegate];
            
            // Notify signalingDelegate that can start peer negotiation for streamId.
            [signalingDelegate signalingChannelDidOpenChannel:self];
            [signalingDelegate signalingChannel:self readyToSubscribeStreamId:streamId peerSocketId:nil];
        } else {
            L_ERROR(@"SignalingChannel couldn't subscribe streamId: %@", streamId);
        }
    };
    return _cb;
}

- (SocketIOCallback)onPublishCallback:(id<ECSignalingChannelDelegate>)signalingDelegate {
    SocketIOCallback _cb = ^(id argsData) {
        L_INFO(@"SignalingChannel Publish callback: %@", argsData);

        NSString *ackString = [NSString stringWithFormat:@"%@", [argsData objectAtIndex:0]];
        if ([[NSString stringWithFormat:@"NO ACK"] isEqualToString:ackString]) {
            NSString *errorString = @"No ACK received when publishing stream!";
            L_ERROR(errorString);
            [self.roomDelegate signalingChannel:self didError:errorString];
            return;
        }

        // Get streamId for the stream to publish.
		id object = [argsData objectAtIndex:0];
		id object1 = [argsData objectAtIndex:1];
		id object2 = [argsData objectAtIndex:2];
		if(!object || !object1 || !object2 || object == [NSNull null] || object1 == [NSNull null] || object2 == [NSNull null]) {
			if([signalingDelegate respondsToSelector:@selector(signalingChannelPublishFailed:)]) {
				[signalingDelegate signalingChannelPublishFailed:self];
			}
			if([_roomDelegate respondsToSelector:@selector(signalingChannel:didError:)]) {
				[_roomDelegate signalingChannel:self
                                       didError:[NSString stringWithFormat:@"%@", [argsData objectAtIndex:1]]];
			}
			return;
		}
        NSString *streamId = [(NSNumber*)[argsData objectAtIndex:0] stringValue];
		NSString *erizoId = (NSString*)[argsData objectAtIndex:1];
		NSString *connectionId = (NSString*)[argsData objectAtIndex:2];
        
        // Client delegate should know about the stream id.
        signalingDelegate.streamId = streamId;
		signalingDelegate.erizoId = erizoId;
		signalingDelegate.connectionId = connectionId;
        
        // Keep track of an unique delegate for this stream id.
        [self setSignalingDelegate:signalingDelegate];
        
        // Notify room and signaling delegates
        [signalingDelegate signalingChannelDidOpenChannel:self];
        [signalingDelegate signalingChannel:self readyToPublishStreamId:streamId peerSocketId:nil];
        [_roomDelegate signalingChannel:self didReceiveStreamIdReadyToPublish:streamId];
    };
    return _cb;
}

- (SocketIOCallback)onUnPublishCallback:(NSString *)streamId {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel Unpublish callback: %@", response);
        if ((BOOL)[response objectAtIndex:0]) {
            [_roomDelegate signalingChannel:self didUnpublishStreamWithId:streamId];
        } else {
            L_ERROR(@"signalingChannel Couldn't unpublish stream id: %@", streamId);
        }
    };
    return _cb;
}

- (SocketIOCallback)onUnSubscribeCallback:(NSString *)streamId {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel Unsubscribe callback: %@", response);
        if ((BOOL)[response objectAtIndex:0]) {
            [_roomDelegate signalingChannel:self didUnsubscribeStreamWithId:streamId];
        } else {
            L_ERROR(@"signalingChannel Couldn't unsubscribe stream id: %@", streamId);
        }
    };
    return _cb;
}

- (SocketIOCallback)onSendTokenCallback2 {
    SocketIOCallback _cb = ^(id argsData) {
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel: onSendTokenCallback: %@", response);
        
        // Get message and status
        NSString *status = (NSString *)[response objectAtIndex:0];
        NSString *message = (NSString *)[response objectAtIndex:1];
        
        // If success store room metadata and notify connection.
        if ([status isEqualToString:@"success"]) {
            roomMetadata = [[response objectAtIndex:1] mutableCopy];
            [roomMetadata setValue:[[roomMetadata objectForKey:@"streams"] mutableCopy] forKey:@"streams"];
            // Convert stream ids to strings just in case they were parsed as longs.
            for (int i=0; i<[[roomMetadata objectForKey:@"streams"] count]; i++) {
                NSDictionary *stream = [[roomMetadata objectForKey:@"streams"][i] mutableCopy];
                NSString *sId = [NSString stringWithFormat:@"%@", [stream objectForKey:@"id"]];
                [stream setValue:sId forKey:@"id"];
                [roomMetadata objectForKey:@"streams"][i] = stream;
            }
            [_roomDelegate signalingChannel:self didConnectToRoom:roomMetadata];
        } else {
            [_roomDelegate signalingChannel:self didError:message];
        }
    };
    return _cb;
}

- (SocketIOCallback)onSendTokenCallback {
    SocketIOCallback _cb = ^(id argsData) {
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel: onSendTokenCallback: %@", response);

        // Get message and status
        NSString *message = (NSString *)[response objectAtIndex:0];

        // If success store room metadata and notify connection.
        if (response.count == 2) {
            roomMetadata = [[response objectAtIndex:0] mutableCopy][@"msg"];
            [roomMetadata setValue:[[roomMetadata objectForKey:@"streams"] mutableCopy] forKey:@"streams"];
            // Convert stream ids to strings just in case they were parsed as longs.
            for (int i = 0; i < [[roomMetadata objectForKey:@"streams"] count]; i++) {
                NSDictionary *stream = [[roomMetadata objectForKey:@"streams"][i] mutableCopy];
                NSString *sId = [NSString stringWithFormat:@"%@", [stream objectForKey:@"id"]];
                [stream setValue:sId forKey:@"id"];
                [roomMetadata objectForKey:@"streams"][i] = stream;
            }
            [_roomDelegate signalingChannel:self didConnectToRoom:roomMetadata];
        } else {
            [_roomDelegate signalingChannel:self didError:message];
        }
    };
    return _cb;
}

- (SocketIOCallback)onStartRecordingCallback:(NSString *)streamId {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel onStartRecordingCallback: %@", response);
        
        NSString  *recordingId;
        NSString  *errorStr;
        NSTimeInterval timestamp;
        NSDate *recordingDate = [NSDate date];
        
        if ([[response objectAtIndex:0] isKindOfClass:[NSNull class]]) {
            errorStr = [response objectAtIndex:1];
        } else if ([[response objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
            recordingId = [[response objectAtIndex:0] objectForKey:@"id"];
            timestamp = [(NSNumber*)[[response objectAtIndex:0] objectForKey:@"timestamp"] integerValue];
            recordingDate = [NSDate dateWithTimeIntervalSince1970:timestamp/1000];
        } else {
            recordingId = [[response objectAtIndex:0] stringValue];
        }
        
        if (!errorStr) {
            [_roomDelegate signalingChannel:self didStartRecordingStreamId:streamId
                            withRecordingId:recordingId
                              recordingDate:recordingDate];
        } else {
            [_roomDelegate signalingChannel:self didFailStartRecordingStreamId:streamId
                               withErrorMsg:errorStr];
        }
    };
    return _cb;
}

#
# pragma mark - Private
#

- (NSNumber *)longStreamId:(NSString *)streamId {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    return [f numberFromString:streamId];
}

- (void)decodeToken:(NSString *)token {
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:token options:0];
	if(!decodedData) {
		return;
	}
    NSError *jsonParseError = nil;
    decodedToken = [NSJSONSerialization
                    JSONObjectWithData:decodedData
                    options:0
                    error:&jsonParseError];
}

- (void)removeSignalingDelegateForKey:(NSString *)key {
    [streamSignalingDelegates setValue:nil forKey:key];
}

- (void)setSignalingDelegate:(id<ECSignalingChannelDelegate>)delegate {
    [streamSignalingDelegates setValue:delegate forKey:[self keyFromDelegate:delegate]];
    [outMessagesQueues setValue:[NSMutableArray array] forKey:[self keyFromDelegate:delegate]];
}

- (NSString *)keyFromDelegate:(id<ECSignalingChannelDelegate>)delegate {
	return [self keyForDelegateWithStreamId:delegate.streamId peerSocketId:delegate.peerSocketId connectionId:delegate.connectionId];
}

- (NSString *)startKeyFromDelegate:(id<ECSignalingChannelDelegate>)delegate {
	return [self startKeyForDelegateWithConnectionId:delegate.connectionId];
}

- (NSString *)keyForDelegateWithStreamId:(NSString *)streamId peerSocketId:(NSString *)peerSocketId connectionId:(NSString *)connectionId{
    return [NSString stringWithFormat:@"%@-%@-%@", connectionId, streamId, peerSocketId];
}

- (NSString *)startKeyForDelegateWithConnectionId:(NSString *)connectionId{
	return [NSString stringWithFormat:@"%@-", connectionId];
}

- (id<ECSignalingChannelDelegate>)signalingDelegateForKey:(NSString *)key {
    return [streamSignalingDelegates objectForKey:key];
}

- (id<ECSignalingChannelDelegate>)signalingDelegateForStartKey:(NSString *)startKey {
	for (NSString* key in streamSignalingDelegates) {
		if ([key hasPrefix:startKey]) {
			return [streamSignalingDelegates objectForKey:key];
		}
	}
	return nil;
}

- (void)sendSocketMessage: (NSArray *)socket type: (NSString *)type {
    [socketIO emit:type with:socket];
    socketgd += 1;
}

- (OnAckCallback *)sendACK: (NSArray *)socket type: (NSString *)type {
    OnAckCallback *callback = [socketIO emitWithAck:type with:socket];
    socketgd += 1;
    return callback;
}

@end
