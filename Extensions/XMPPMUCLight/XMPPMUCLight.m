//
//  XMPPMUCLight.m
//  Mangosta
//
//  Created by Andres on 5/30/16.
//  Copyright © 2016 Inaka. All rights reserved.
//

#import "XMPPMUC.h"
#import "XMPPFramework.h"
#import "XMPPLogging.h"
#import "XMPPIDTracker.h"
#import "XMPPMUCLight.h"
#import "XMPPRoomLight.h"

NSString *const XMPPMUCLightDiscoItemsNamespace = @"http://jabber.org/protocol/disco#items";
NSString *const XMPPRoomLightAffiliations = @"urn:xmpp:muclight:0#affiliations";
NSString *const XMPPMUCLightErrorDomain = @"XMPPMUCErrorDomain";

@implementation XMPPMUCLight

- (instancetype)init
{
	self = [self initWithDispatchQueue:nil];
	if (self) {

	}
	return self;
}

- (id)initWithDispatchQueue:(dispatch_queue_t)queue
{
	if ((self = [super initWithDispatchQueue:queue])) {
		_rooms = [[NSMutableSet alloc] init];
	}
	return self;
}


- (BOOL)activate:(XMPPStream *)aXmppStream
{
	if ([super activate:aXmppStream])
	{
		xmppIDTracker = [[XMPPIDTracker alloc] initWithDispatchQueue:moduleQueue];
		return YES;
	}
	
	return NO;
}

- (void)deactivate
{
	dispatch_block_t block = ^{ @autoreleasepool {
		[xmppIDTracker removeAllIDs];
		xmppIDTracker = nil;
	}};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_sync(moduleQueue, block);
	
	[super deactivate];
}

- (BOOL)discoverRoomsForServiceNamed:(NSString *)serviceName {
	
	if (serviceName.length < 2)
		return NO;
	
	dispatch_block_t block = ^{ @autoreleasepool {

		NSXMLElement *query = [NSXMLElement elementWithName:@"query"
													  xmlns:XMPPMUCLightDiscoItemsNamespace];
		XMPPIQ *iq = [XMPPIQ iqWithType:@"get"
									 to:[XMPPJID jidWithString:serviceName]
							  elementID:[xmppStream generateUUID]
								  child:query];
		
		[xmppIDTracker addElement:iq
						   target:self
						 selector:@selector(handleDiscoverRoomsQueryIQ:withInfo:)
						  timeout:60];
		
		[xmppStream sendElement:iq];
	}};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
	
	return YES;
}

- (void)handleDiscoverRoomsQueryIQ:(XMPPIQ *)iq withInfo:(XMPPBasicTrackingInfo *)info
{
	dispatch_block_t block = ^{ @autoreleasepool {
		NSXMLElement *errorElem = [iq elementForName:@"error"];
		NSString *serviceName = [iq attributeStringValueForName:@"from" withDefaultValue:@""];
		
		if (errorElem) {
			NSString *errMsg = [errorElem.children componentsJoinedByString:@", "];
			NSInteger errorCode = [errorElem attributeIntegerValueForName:@"code" withDefaultValue:0];
			NSDictionary *dict = @{NSLocalizedDescriptionKey : errMsg};
			NSError *error = [NSError errorWithDomain:XMPPMUCLightErrorDomain
												 code:errorCode
											 userInfo:dict];
			
			[multicastDelegate xmppMUCLight:self failedToDiscoverRoomsForServiceNamed:serviceName withError:error];
			return;
		}
		
		NSXMLElement *query = [iq elementForName:@"query"
										   xmlns:XMPPMUCLightDiscoItemsNamespace];
		
		NSArray *items = [query elementsForName:@"item"];

		[multicastDelegate xmppMUCLight:self didDiscoverRooms:items forServiceNamed:serviceName];
		
	}};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark XMPPStream Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)message {

	//  <message from='coven@muclight.shakespeare.lit'
	//           to='user2@shakespeare.lit'
	//           type='groupchat'
	//           id='createnotif'>
	//      <x xmlns='urn:xmpp:muclight:0#affiliations'>
	//          <version>aaaaaaa</version>
	//          <user affiliation='member'>user2@shakespeare.lit</user>
	//      </x>
	//      <body />
	//  </message>

	XMPPJID *from = message.from;
	NSXMLElement *x = [message elementForName:@"x" xmlns:XMPPRoomLightAffiliations];
	NSXMLElement *user  = [x elementForName:@"user"];
	NSString *affiliation = [user attributeForName:@"affiliation"].stringValue;
	
	if (affiliation) {
		[multicastDelegate xmppMUCLight:self changedAffiliation:affiliation roomJID:from];
	}
}

- (void)xmppStream:(XMPPStream *)sender didRegisterModule:(id)module {
	
	if ([module isKindOfClass:[XMPPRoomLight class]]){
		
		XMPPJID *roomJID = [(XMPPRoomLight *)module roomJID];
		
		[_rooms addObject:roomJID];
	}
}

- (void)xmppStream:(XMPPStream *)sender willUnregisterModule:(id)module {
	
	if ([module isKindOfClass:[XMPPRoomLight class]]){
		
		XMPPJID *roomJID = [(XMPPRoomLight *)module roomJID];
		
		// It's common for the room to get deactivated and deallocated before
		// we've received the goodbye presence from the server.
		// So we're going to postpone for a bit removing the roomJID from the list.
		// This way the isMUCRoomElement will still remain accurate
		// for presence elements that may arrive momentarily.
		
		double delayInSeconds = 30.0;
		dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
		dispatch_after(popTime, moduleQueue, ^{ @autoreleasepool {
			[_rooms removeObject:roomJID];
		}});
	}
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq {
	NSString *type = [iq type];

	if ([type isEqualToString:@"result"] || [type isEqualToString:@"error"]) {
		return [xmppIDTracker invokeForID:[iq elementID] withObject:iq];
	}

	return NO;
}


@end
