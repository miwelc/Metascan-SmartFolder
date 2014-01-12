//
//  SFAppDelegate.h
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 18/10/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#ifndef _SFAPPDELEGATE_H_
#define _SFAPPDELEGATE_H_

#import <Cocoa/Cocoa.h>
#include "monitor.h"
#include "scanner.h"
#include "DB.h"
#include "CNUserNotification.h"

@interface SFAppDelegate : NSObject
	<NSApplicationDelegate, NSWindowDelegate, CNUserNotificationCenterDelegate, NSTextFieldDelegate, NSTableViewDataSource>
{
	Scanner* scanner;
	pthread_t monitorThread, scannerThread;
	NSString *SFbaseDir;
	NSString *APIKey;
	DBResults infectedFiles;
	
	//UI Elements
	CNUserNotificationCenter *notificationCenter;
	NSWindow *_installWindow;
    IBOutlet NSMenu *statusMenu;
    NSStatusItem * statusItem;
	NSMenuItem *_configureMenuItem;
	NSMenuItem *_pauseResumeItem;
	
	NSWindow *_configWindow;
	NSView *currentView;
	NSToolbar *_configToolbar;
	
	NSView *_confGeneralView;
	NSTextField *_dirLabel;
	NSPopUpButton *_rescanTimeButton;

	NSView *_confAccountView;
	NSTextField *_apiKeyTextField;
	NSImageView *_correctKeyImg;
	
	NSView *_confResultsView;
	NSTableView *_resultsTableView;
	
	NSView *_confAboutView;
	
	NSPanel *_legalPanel;
}

- (IBAction)selectFolder:(id)sender;
- (IBAction)showConfiguration:(id)sender;
- (IBAction)switchConfView:(id)sender;

- (void)notifyUser:(CNUserNotification*)notification;
- (void)wrongKey;

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

@property (strong) IBOutlet NSMenuItem *configureMenuItem;
@property (strong) IBOutlet NSTextField *dirLabel;

@property (strong) IBOutlet NSWindow *configWindow;
@property (strong) IBOutlet NSView *confGeneralView;
@property (strong) IBOutlet NSView *confAccountView;
@property (strong) IBOutlet NSView *confResultsView;
@property (strong) IBOutlet NSView *confAboutView;
@property (strong) IBOutlet NSToolbar *configToolbar;
@property (strong) IBOutlet NSTextField *apiKeyTextField;
@property (strong) IBOutlet NSMenuItem *pauseResumeItem;
@property (strong) IBOutlet NSWindow *installWindow;
@property (strong) IBOutlet NSPanel *legalPanel;
@property (strong) IBOutlet NSImageView *correctKeyImg;
@property (strong) IBOutlet NSTableView *resultsTableView;
@property (strong) IBOutlet NSPopUpButton *rescanTimeButton;
@end

#endif
