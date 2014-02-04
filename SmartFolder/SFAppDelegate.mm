//
//  SFAppDelegate.m
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 18/10/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#include <pthread.h>
#import <QuartzCore/CoreAnimation.h>
#import "SFAppDelegate.h"
#import "PFMoveApplication.h"
#include "version.h"

#define SF_DEBUG 0

SFAppDelegate *appDelegate;

@implementation SFAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	appDelegate = self;
	
	notificationCenter = [CNUserNotificationCenter customUserNotificationCenter];
	notificationCenter.delegate = self;
	
#if (SF_DEBUG==0)
	//Path of the bundle
	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	//Install the application if it isn't in Applications folder
	if(IsInApplicationsFolder(bundlePath) == false) {
		//Show License window
		[NSApp runModalForWindow:_installWindow];
		if(PFMoveToApplicationsFolderIfNecessary()) {
			[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"JustInstalled"];
			[[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"RescanTime"];
			[[NSUserDefaults standardUserDefaults] synchronize];
			exit(0);
		}
	}
	else if([[NSUserDefaults standardUserDefaults] boolForKey:@"JustInstalled"]){
		CNUserNotification *notification = [CNUserNotification new];
		notification.title = @"SmartFolder";
		notification.subtitle = @"Installation completed succesfully!";
		notification.informativeText = @"Application currently running on the status bar";
		notification.hasActionButton = NO;
		notification.feature.dismissDelayTime = 8;
		notification.feature.bannerImage = [NSApp applicationIconImage];
		notification.soundName = CNUserNotificationDefaultSound;
		notification.userInfo = @{ @"notificationType": @"installed" };
		[notificationCenter deliverNotification:notification];
		[[NSUserDefaults standardUserDefaults] setBool:FALSE forKey:@"JustInstalled"];
		[[NSUserDefaults standardUserDefaults] synchronize];
	}
#endif
	
	//Create icon on the status bar
	statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [statusItem setMenu:statusMenu];
    [statusItem setTitle:@"SF"];
    [statusItem setHighlightMode:YES];
	
	//Configuration window
	[_configWindow close];
	[_configWindow setContentSize:[_confGeneralView frame].size];
	[[_configWindow contentView] addSubview:_confGeneralView];
	[[_configWindow contentView] setWantsLayer:YES];
	currentView = _confGeneralView;
	[_configToolbar setSelectedItemIdentifier:@"smartFolderToolbarItem"];
    [_configWindow setDelegate:self];
	[_apiKeyTextField setDelegate:self];
	
	//Create a working directory in the user's Application Support folder
	NSString *workingDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
															   NSUserDomainMask,
															   YES)[0];
	workingDir = [workingDir stringByAppendingString:@"/"];
	workingDir = [workingDir stringByAppendingString:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleExecutable"] ];
	[[NSFileManager defaultManager] createDirectoryAtPath:workingDir
	 withIntermediateDirectories:YES
	 attributes:nil
	 error:nil];
	Scanner::initialize([workingDir UTF8String]);
	
	//Load configuration
	[self setRescanTimeForTag:[[NSUserDefaults standardUserDefaults] integerForKey:@"RescanTime"]];
	APIKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"APIKey"];
	if(APIKey == NULL)
		APIKey = @"";
	[_apiKeyTextField setStringValue:APIKey];
	Scanner::setAPIKey([APIKey UTF8String]);
	
	BOOL isDir;
	SFbaseDir = [[NSUserDefaults standardUserDefaults] stringForKey:@"SmartFolderBaseDir"];
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	if([fileManager fileExistsAtPath:SFbaseDir isDirectory:&isDir] && isDir) {
		[_dirLabel setStringValue:SFbaseDir];
		//Start monitoring
		[self initThreads];
	}
	else { //Base path doesn't exist, we ask for it
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText:@"Please, select the base directory for SmartFolder"];
		[[alert window] setCollectionBehavior: NSWindowCollectionBehaviorCanJoinAllSpaces];
		[[alert window] setLevel: NSFloatingWindowLevel];
		while(([fileManager fileExistsAtPath:SFbaseDir isDirectory:&isDir] && isDir) == false) {
			[alert runModal];
			[self selectFolder:self];
		}
	}
}

- (BOOL)userNotificationCenter:(CNUserNotificationCenter *)center shouldPresentNotification:(CNUserNotification *)notification {
	//NSString* notificationType = [notification.userInfo objectForKey:@"notificationType"];
	//if([notificationType  isEqual: @"infected"]) {
	//	[self shouldUpdateScanTable];
	//}
	return YES;
}

- (void)userNotificationCenter:(CNUserNotificationCenter *)center didActivateNotification:(CNUserNotification *)notification {
	NSString* notificationType = [notification.userInfo objectForKey:@"notificationType"];
	if([notificationType  isEqual: @"infected"]) {
		[self showConfiguration:self];
		[self switchConfViewToview:_confResultsView];
	}
}

- (IBAction)installButtonClicked:(id)sender {
	[NSApp stopModal];
	[_installWindow close];
}


- (IBAction)selectFolder:(id)sender {
    NSOpenPanel* openDlg = [NSOpenPanel openPanel];
	
	[openDlg setTitle:@"Please, select folder:"];
	
	//Only Directories
    [openDlg setCanChooseFiles:NO];
    [openDlg setCanChooseDirectories:YES];
	[openDlg setPrompt:@"Select"];
	
	if([openDlg runModal] == NSOKButton) {
		NSString *folder = [[openDlg URL] path];
		[_dirLabel setStringValue:folder];
		[[NSUserDefaults standardUserDefaults] setValue:folder forKey:@"SmartFolderBaseDir"];
		[[NSUserDefaults standardUserDefaults] synchronize];
		
		[self cleanup];
		SFbaseDir = folder;
		[self initThreads];
	}
}

- (IBAction)changedRescanTime:(id)sender {
	[self setRescanTimeForTag:[sender tag]];
}
- (void)setRescanTimeForTag:(NSInteger) tag {
	switch (tag) {
		case 0:
			NSLog(@"Rescan time set to never");
			[[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"RescanTime"];
			Scanner::setRescanTime(-1);
			[_rescanTimeButton selectItemWithTag:0];
			break;
		case 1:
			NSLog(@"Rescan time set to monthly");
			[[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"RescanTime"];
			Scanner::setRescanTime(30*24*60*60);
			[_rescanTimeButton selectItemWithTag:1];
			break;
		case 2:
			NSLog(@"Rescan time set to weekly");
			[[NSUserDefaults standardUserDefaults] setInteger:2 forKey:@"RescanTime"];
			Scanner::setRescanTime(7*24*60*60);
			[_rescanTimeButton selectItemWithTag:2];
			break;
		case 3:
			NSLog(@"Rescan time set to daily");
			[[NSUserDefaults standardUserDefaults] setInteger:3 forKey:@"RescanTime"];
			Scanner::setRescanTime(24*60*60);
			[_rescanTimeButton selectItemWithTag:3];
			break;
		case 4:
			NSLog(@"Rescan time set to every 5h");
			[[NSUserDefaults standardUserDefaults] setInteger:4 forKey:@"RescanTime"];
			Scanner::setRescanTime(5*60*60);
			[_rescanTimeButton selectItemWithTag:4];
			break;
			
		default:
			NSLog(@"Rescan time set to never");
			[[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"RescanTime"];
			Scanner::setRescanTime(-1);
			[_rescanTimeButton selectItemWithTag:0];
			break;
	}
	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)wrongKeyAlert {
	//APIKey = @"";
	//[_apiKeyTextField setStringValue:APIKey];
	
	NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Please, type a correct API Key"];
	[alert setInformativeText:@"SmartFolder requires a valid Metascan API key in order to scan your files. Metascan provides the malware detection tools used by this software."];
	[[alert window] setCollectionBehavior: NSWindowCollectionBehaviorCanJoinAllSpaces];
	[[alert window] setLevel: NSFloatingWindowLevel];
	[alert runModal];
	
	[_correctKeyImg setImage:[NSImage imageNamed:@"NSStopProgressTemplate"]];
	[self showConfiguration:self];
	[self switchConfViewToview:_confAccountView];
}

- (bool)isValidApiKey:(NSString*)key {
	if([key length] != 32)
		return false;
	else
		return Scanner::isValidAPIKey([key UTF8String]);
}

//Only allow up to 32 hexadecimal characters in the API Key
- (void)controlTextDidChange:(NSNotification *)aNotification {
    NSControl *textField = [aNotification object];
    NSString *oldString = [textField stringValue];
	
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"([^0123456789abcdef])" options:NSRegularExpressionCaseInsensitive error:nil];
	NSString *newString = [regex stringByReplacingMatchesInString:oldString options:0 range:NSMakeRange(0, [oldString length]) withTemplate:@""];
	newString = ([newString length] > 32 ? [newString substringToIndex:32] : newString);
	
	[textField setStringValue:[newString lowercaseString]];
	if([self isValidApiKey:newString])
		[_correctKeyImg setImage:[NSImage imageNamed:@"NSMenuOnStateTemplate"]];
	else {
		[_correctKeyImg setImage:[NSImage imageNamed:@"NSStopProgressTemplate"]];
		//Shake the window and play an error sound
		if([newString length] == 32) {
			[_configWindow setAnimations:[NSDictionary dictionaryWithObject:[self shakeAnimation:[_configWindow frame]] forKey:@"frameOrigin"]];
			[[_configWindow animator] setFrameOrigin:[_configWindow frame].origin];
			[self playErrorSound];
		}
	}
}

- (IBAction)editedAPIKey:(id)sender {
    NSString *newKey = [_apiKeyTextField stringValue];
	NSString *oldKey = [APIKey copy];
	
	if ([newKey isEqualToString:oldKey] == false) {
		APIKey = [newKey copy];
		[[NSUserDefaults standardUserDefaults] setValue:APIKey forKey:@"APIKey"];
		[[NSUserDefaults standardUserDefaults] synchronize];
		Scanner::setAPIKey([APIKey UTF8String]);
	
		//If the previous one wasn't a good key we start the threads now
		if([self isValidApiKey:oldKey] == false)
			[self initThreads];
	
		NSLog(@"API Key changed to %s", [APIKey UTF8String]);
	}
}

- (BOOL)windowShouldClose:(id)sender {
	[self editedAPIKey:self];
    
    if([self isValidApiKey:APIKey] == false) {
		[self wrongKeyAlert];
        return NO;
    }
    else {
        return YES;
    }
}

- (IBAction)showConfiguration:(id)sender {
	if([APIKey length] > 0)
		[_apiKeyTextField setStringValue:APIKey];
	[self switchConfViewToview:_confGeneralView];
	[NSApp activateIgnoringOtherApps:YES];
	[_configWindow setCollectionBehavior: NSWindowCollectionBehaviorCanJoinAllSpaces];
	NSRect frame = [[NSScreen mainScreen] visibleFrame];
    NSPoint point = NSMakePoint(frame.size.width/2, frame.size.height);
	[_configWindow setFrameOrigin:point];
	[_configWindow makeKeyAndOrderFront:self];
	[_configWindow setLevel: NSFloatingWindowLevel];
}

- (IBAction)showScanStatus:(id)sender {
	[self showConfiguration:self];
	[self switchConfViewToview:_confResultsView];
}

- (IBAction)showLegal:(id)sender {
	[NSApp activateIgnoringOtherApps:YES];
	[_legalPanel setCollectionBehavior: NSWindowCollectionBehaviorCanJoinAllSpaces];
	NSRect frame = [[NSScreen mainScreen] visibleFrame];
    NSPoint point = NSMakePoint(frame.size.width/2, frame.size.height);
	[_legalPanel setFrameOrigin:point];
	[_legalPanel makeKeyAndOrderFront:self];
	//[_legalPanel setLevel: NSFloatingWindowLevel];
}

- (IBAction)switchConfView:(id)sender {
	NSInteger tag = [sender tag];
	NSView *newView;
	switch (tag) {
		case 0: default:
			newView = _confGeneralView;
			break;
		case 1:
			newView = _confAccountView;
			break;
		case 2:
			newView = _confResultsView;
			break;
		case 5:
			newView = _confAboutView;
			break;
	}
	
	[self switchConfViewToview:newView];
}

- (void)switchConfViewToview:(NSView*)newView {
	if(newView == _confGeneralView)
		[_configToolbar setSelectedItemIdentifier:@"smartFolderToolbarItem"];
	else if(newView == _confAccountView)
		[_configToolbar setSelectedItemIdentifier:@"accountToolbarItem"];
	else if(newView == _confResultsView) {
		[_configToolbar setSelectedItemIdentifier:@"resultsToolbarItem"];
		[self shouldUpdateScanTable];
	}
	else if(newView == _confAboutView) {
		[_configToolbar setSelectedItemIdentifier:@"aboutToolbarItem"];
	}
	
	NSRect oldContentFrame = [currentView frame];
	NSRect newContentFrame = [newView frame];
	float widthDifference = newContentFrame.size.width - oldContentFrame.size.width;
	float heightDifference = newContentFrame.size.height - oldContentFrame.size.height;
	
	NSRect windowFrame = [_configWindow frame];
	windowFrame.size.width += widthDifference;
	windowFrame.size.height += heightDifference;
	windowFrame.origin.y -= heightDifference;
	
	//[[[_configWindow contentView] animator] replaceSubview:currentView with:newView];
	[currentView removeFromSuperview];
	[[_configWindow contentView] addSubview:newView];
	[_configWindow setFrame:windowFrame display:YES animate:YES];
	
	currentView = newView;
}

- (void)shouldUpdateScanTable {
	Scanner::getAllFilesStatus(&filesStatus);
	[_resultsTableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
	return filesStatus.size();
}

-(id) tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	DBRow fileInfo = filesStatus[row];
	string path = fileInfo["PATH"];
	int state = atoi(fileInfo["STATE"].c_str());
	int scanResult;
	
	NSString* identifier = [tableColumn identifier];
	if([identifier isEqual:@"status"]) {
		switch(state) {
			case SENDING:
				return @"Sending";
			case SCANNING:
				return @"Scanning";
			case SCANNED:
				scanResult = atoi(fileInfo["SCAN_RESULT"].c_str());
				switch(scanResult) {
					case 0: case 7:
						return @"Clean";
					case 1: case 4: case 6: case 8:
						return @"Infected";
					case 2:
						return @"Suspicious";
					case 3: case 5: case 9: case 10: case 11:
					case 12: case 13: case 14: default:
						return @"Failed to scan";
				}
			case NOT_SCANNED:
			default:
				return @"Pending";
		}
	}
	else if([identifier isEqual:@"filename"]) {
		return [NSString stringWithUTF8String:path.substr(path.find_last_of("/")+1).c_str()];
	}
	else if([identifier isEqual:@"path"]) {
		return [NSString stringWithUTF8String:path.c_str()];
	}
	else return @"";
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if([[col identifier] isEqual:@"status"]) {
		if(atoi(filesStatus[row]["STATE"].c_str()) == SCANNED) {
			int scanResult = atoi(filesStatus[row]["SCAN_RESULT"].c_str());
			switch(scanResult) {
				case 1: case 4: case 6: case 8:
					[cell setBackgroundColor:[NSColor colorWithCalibratedRed:1.0f green:0.3f blue:0.3f alpha:1.0]];
					[cell setTextColor:[NSColor whiteColor]];
					[cell setDrawsBackground:YES];
					break;
				case 2:
					[cell setBackgroundColor:[NSColor yellowColor]];
					[cell setTextColor:[NSColor blackColor]];
					[cell setDrawsBackground:YES];
					break;
				default:
					[cell setTextColor:[NSColor blackColor]];
					[cell setDrawsBackground:NO];
			}
		}
		else {
			[cell setTextColor:[NSColor blackColor]];
			[cell setDrawsBackground:NO];
		}
	}
}

- (IBAction)switchPauseResume:(id)sender {
	NSInteger tag = [sender tag];
	switch (tag) {
		case 0: default:
			[self cleanup];
			break;
		case 1:
			[self initThreads];
			break;
	}
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	[self cleanup];
	NSLog(@"BYEEE");
	
	return NSTerminateNow;
}

- (void)initThreads {
    pthread_attr_t  attr;
	int error;
	
	if(monitorThread || scannerThread)
		return;
	
	if([self isValidApiKey:[NSString stringWithUTF8String:Scanner::getAPIKey().c_str()]] == false) {
		[self wrongKeyAlert];
		return;
	}
	
	//Create monitor thread
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
    error = pthread_create(&monitorThread, &attr, &Monitor::startMonitoring, (void*)[SFbaseDir UTF8String]);
    pthread_attr_destroy(&attr);
    if(error != 0) {
		NSLog(@"Cannot create monitor thread, exiting\n");
		[NSApp terminate:self];
    }
	//Create scanner thread
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
    error = pthread_create(&scannerThread, &attr, &Scanner::startScanning, (void*)[SFbaseDir UTF8String]);
    pthread_attr_destroy(&attr);
    if(error != 0) {
		NSLog(@"Cannot create scanner thread, exiting\n");
		[NSApp terminate:self];
    }
	
	[_pauseResumeItem setTitle:@"Pause"];
	[_pauseResumeItem setTag:0];
}

- (void)cleanup {
	Monitor::endMonitoring();
	Scanner::endScanning();
	
	if(monitorThread) {
		pthread_join(monitorThread, NULL);
		monitorThread = 0;
	}
	if(scannerThread) {
		pthread_join(scannerThread, NULL);
		scannerThread = 0;
	}
	
	[_pauseResumeItem setTitle:@"Resume"];
	[_pauseResumeItem setTag:1];
}

- (void)notifyUser:(CNUserNotification*)notification {
	[notificationCenter deliverNotification:notification];
}

- (void)playErrorSound {
	NSSound *sound;
	if(runningMLOrLater())
		sound = [[NSSound alloc] initWithContentsOfFile:@"/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Volume Mount.aif" byReference:YES];
	else
		sound = [[NSSound alloc] initWithContentsOfFile:@"/System/Library/Components/CoreAudio.component/Contents/Resources/SystemSounds/system/Volume Mount.aif" byReference:YES];
	if(sound) {
		[sound play];
	}
}


/*
* Author: Matt Long
* Link: http://www.cimgf.com/2008/02/27/core-animation-tutorial-window-shake-effect/
*/
- (CAKeyframeAnimation *)shakeAnimation:(NSRect)frame {
	const int numberOfShakes = 7;
	const float durationOfShake = 0.5f;
	const float vigourOfShake = 0.04f;
    CAKeyframeAnimation *shakeAnimation = [CAKeyframeAnimation animation];
	
    CGMutablePathRef shakePath = CGPathCreateMutable();
    CGPathMoveToPoint(shakePath, NULL, NSMinX(frame), NSMinY(frame));
	
	for(int index = 0; index < numberOfShakes; ++index) {
		CGPathAddLineToPoint(shakePath, NULL, NSMinX(frame) - frame.size.width * vigourOfShake, NSMinY(frame));
		CGPathAddLineToPoint(shakePath, NULL, NSMinX(frame) + frame.size.width * vigourOfShake, NSMinY(frame));
	}
    CGPathCloseSubpath(shakePath);
    shakeAnimation.path = shakePath;
    shakeAnimation.duration = durationOfShake;
    return shakeAnimation;
}

@end
