/*
 * Copyright (c) 2013 Dan Wilcox <danomatika@gmail.com>
 *
 * BSD Simplified License.
 * For information on usage and redistribution, and for a DISCLAIMER OF ALL
 * WARRANTIES, see the file, "LICENSE.txt," in this distribution.
 *
 * See https://github.com/danomatika/PdParty for documentation
 *
 */
 #import "SceneManager.h"

#import <CoreMotion/CoreMotion.h>
#import "Log.h"
#import "Gui.h"
#import "AppDelegate.h"

#define ACCEL_UPDATE_HZ	60.0

@interface SceneManager () {
	CMMotionManager *motionManager; // for accel data
	UIDeviceOrientation currentDeviceOrientation; // rotation degrees based on this
	BOOL hasReshaped; // has the gui been reshaped?
}

@property (strong, readwrite, nonatomic) NSString* currentPath;
@property (assign, readwrite, getter=isRecording, nonatomic) BOOL recording;

// called by the device notificaiton center
- (void)deviceOrientationChanged:(NSNotification *)notification;

@end

@implementation SceneManager

- (id)init {
	self = [super init];
	if(self) {
		
		hasReshaped = NO;
		
		// init motion manager
		motionManager = [[CMMotionManager alloc] init];
		
		// current UI orientation for accel
		if([Util isDeviceATablet]) { // iPad can started rotated
			self.currentOrientation = [[UIApplication sharedApplication] statusBarOrientation];
		}
		else { // do not start rotated on iPhone
			self.currentOrientation = UIInterfaceOrientationPortrait;
		}
		currentDeviceOrientation = [[UIDevice currentDevice] orientation];
		
		// set osc and pure data pointer
		AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication] delegate];
		self.osc = app.osc;
		self.pureData = app.pureData;
		
		// create gui
		self.gui = [[Gui alloc] init];
	}
		
	return self;
}

- (BOOL)openScene:(NSString *)path withType:(SceneType)type forParent:(UIView *)parent {
	if([self.currentPath isEqualToString:path]) {
		DDLogVerbose(@"SceneManager openScene: ignoring scene with same path");
		return NO;
	}
	
	// close open scene
	[self closeScene];
	
	// open new scene
	switch(type) {
		case SceneTypePatch:
			self.scene = [PatchScene sceneWithParent:parent andGui:self.gui];
			break;
		case SceneTypeRj:
			self.scene = [RjScene sceneWithParent:parent andDispatcher:self.pureData.dispatcher];
			break;
		case SceneTypeDroid:
			self.scene = [DroidScene sceneWithParent:parent andGui:self.gui];
			break;
		case SceneTypeParty:
			self.scene = [PartyScene sceneWithParent:parent andGui:self.gui];
			break;
		case SceneTypeRecording:
			self.scene = [RecordingScene sceneWithParent:parent andPureData:self.pureData];
			break;
		default: // SceneTypeEmpty
			self.scene = [[Scene alloc] init];
			break;
	}
	self.pureData.audioEnabled = YES;
	self.pureData.sampleRate = self.scene.sampleRate;
	self.enableAccelerometer = self.scene.requiresAccel;
	self.enableRotation = self.scene.requiresRotation;
	self.pureData.playing = YES;
	[self.scene open:path];
	
	// turn up volume & turn on transport, update gui
	[self.pureData sendCurrentPlayValues];
	
	// store current location
	self.currentPath = path;
	
	return YES;
}

- (void)closeScene {
	if(self.scene) {
		if(self.pureData.isRecording) {
			[self.pureData stopRecording];
		}
		[self.scene close];
		self.scene = nil;
		self.enableAccelerometer = NO;
		hasReshaped = NO;
	}
}

- (void)reshapeToParentSize:(CGSize)size {
	
	self.gui.parentViewSize = size;
	
	if(!self.scene) {
		return;
	}
		
	// do animations if gui has already been setup once
	// http://www.techotopia.com/index.php/Basic_iOS_4_iPhone_Animation_using_Core_Animation
	if(hasReshaped) {
		[UIView beginAnimations:nil context:nil];
	}
	[self.scene reshape];
	if(hasReshaped) {
		[UIView commitAnimations];
	}
	else {
		hasReshaped = YES;
	}
}

- (void)updateParent:(UIView *)parent {
	if(!self.scene) {
		return;
	}
	self.scene.parentView = parent;
}

#pragma mark Send Events

- (void)sendTouch:(NSString *)eventType forId:(int)id atX:(float)x andY:(float)y {
	if(self.scene.requiresTouch) {
		[PureData sendTouch:eventType forId:id atX:x andY:y];
	}
	if(self.osc.isListening) {
		[self.osc sendTouch:eventType forId:id atX:x andY:y];
	}
}

- (void)sendRotate:(NSString *)orientation withDegreesZ:(float)degreesZ andDegreesXY:(float)degreesXY {
	if(self.scene.requiresRotation) {
		[PureData sendRotate:orientation withDegreesZ:degreesZ andDegreesXY:degreesXY];
	}
	if(self.osc.isListening) {
		[self.osc sendRotate:orientation withDegreesZ:degreesZ andDegreesXY:degreesXY];
	}
}

// pd key event
- (void)sendKey:(int)key {
	if(self.scene.requiresKeys) {
		[PureData sendKey:key];
	}
	if(self.osc.isListening) {
		[self.osc sendKey:key];
	}
}

#pragma mark Overridden Getters / Setters

- (void)setEnableAccelerometer:(BOOL)enableAccelerometer {
	if(self.enableAccelerometer == enableAccelerometer) {
		return;
	}
	_enableAccelerometer = enableAccelerometer;
	
	// start
	if(enableAccelerometer) {
		if([motionManager isAccelerometerAvailable]) {
			NSTimeInterval updateInterval = 1.0/ACCEL_UPDATE_HZ;
			[motionManager setAccelerometerUpdateInterval:updateInterval];
			
			// accel data callback block
			[motionManager startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue]
				withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
//					DDLogVerbose(@"accel %f %f %f", accelerometerData.acceleration.x,
//													accelerometerData.acceleration.y,
//													accelerometerData.acceleration.z);
					// orient accel data to current orientation
					switch(self.currentOrientation) {
						case UIInterfaceOrientationPortrait:
							[PureData sendAccel:accelerometerData.acceleration.x
											  y:accelerometerData.acceleration.y
											  z:accelerometerData.acceleration.z];
							if(self.osc.isListening) {
								[self.osc sendAccel:accelerometerData.acceleration.x
												  y:accelerometerData.acceleration.y
												  z:accelerometerData.acceleration.z];
							}
							break;
						case UIInterfaceOrientationLandscapeRight:
							[PureData sendAccel:-accelerometerData.acceleration.y
											  y:accelerometerData.acceleration.x
											  z:accelerometerData.acceleration.z];
							if(self.osc.isListening) {
								[self.osc sendAccel:-accelerometerData.acceleration.y
												  y:accelerometerData.acceleration.x
												  z:accelerometerData.acceleration.z];
							}
							break;
						case UIInterfaceOrientationPortraitUpsideDown:
							[PureData sendAccel:-accelerometerData.acceleration.x
											  y:-accelerometerData.acceleration.y
											  z:accelerometerData.acceleration.z];
							if(self.osc.isListening) {
								[self.osc sendAccel:-accelerometerData.acceleration.x
												  y:-accelerometerData.acceleration.y
												  z:accelerometerData.acceleration.z];
							}
							break;
						case UIInterfaceOrientationLandscapeLeft:
							[PureData sendAccel:accelerometerData.acceleration.y
											  y:-accelerometerData.acceleration.x
											  z:accelerometerData.acceleration.z];
							if(self.osc.isListening) {
								[self.osc sendAccel:accelerometerData.acceleration.y
												  y:-accelerometerData.acceleration.x
												  z:accelerometerData.acceleration.z];
							}
							break;
					}
				}];
			DDLogVerbose(@"SceneManager: enabled accel");
		}
		else {
			DDLogWarn(@"SceneManager: couldn't enable accel, accel not available on this device");
		}
	}
	else { // stop
		if([motionManager isAccelerometerActive]) {
			[motionManager stopAccelerometerUpdates];
			DDLogVerbose(@"SceneManager: disabled accel");
		}
	}
}

// from https://developer.apple.com/library/ios/documentation/EventHandling/Conceptual/EventHandlingiPhoneOS/motion_event_basics/motion_event_basics.html
- (void)setEnableRotation:(BOOL)enableRotation {
	if(self.enableRotation == enableRotation) {
		return;
	}
	_enableRotation = enableRotation;
	
	// start
	if(enableRotation) {
		[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(deviceOrientationChanged:)
													 name:UIDeviceOrientationDidChangeNotification
												   object:nil];
	}
	else { // stop
		[[NSNotificationCenter defaultCenter] removeObserver:self];
		[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
	}
}

#pragma mark Device Events

- (void)deviceOrientationChanged:(NSNotification *)notification {
	
	UIDeviceOrientation newOrientation = [[UIDevice currentDevice] orientation];
	
	int degreesZ = 0, degreesXY = 0;
	if(newOrientation != UIDeviceOrientationFaceDown && newOrientation != UIDeviceOrientationFaceUp) {
		degreesZ = [Util orientationInDegrees:currentDeviceOrientation] - [Util orientationInDegrees:newOrientation];
	}
	else {
		degreesXY = [Util orientationInDegrees:currentDeviceOrientation] - [Util orientationInDegrees:newOrientation];
	}
	
	NSString *string;
	switch(newOrientation) {
		case UIDeviceOrientationPortrait:
			string = PARTY_ORIENT_PORTRAIT;
			break;
		case UIDeviceOrientationPortraitUpsideDown:
			string = PARTY_ORIENT_PORTRAIT_UPSIDEDOWN;
			break;
		case UIDeviceOrientationLandscapeLeft:
			string = PARTY_ORIENT_LANDSCAPE_LEFT;
			break;
		case UIDeviceOrientationLandscapeRight:
			string = PARTY_ORIENT_LANDSCAPE_RIGHT;
			break;
		case UIDeviceOrientationFaceUp:
			string = PARTY_ORIENT_FACE_UP;
			break;
		case UIDeviceOrientationFaceDown:
			string = PARTY_ORIENT_FACE_DOWN;
			break;
		case UIDeviceOrientationUnknown:
			string = @"unknown"; // should never be called
			break;
	}
	
	DDLogVerbose(@"device rotation: %@ %d %d", string, degreesZ, degreesXY);
	[self sendRotate:string withDegreesZ:degreesZ andDegreesXY:degreesXY];
	currentDeviceOrientation = newOrientation;
}

@end