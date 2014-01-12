//
//  PFMoveApplication.m, version 1.8
//  LetsMove
//
//  Created by Andy Kim at Potion Factory LLC on 9/17/09
//
//  The contents of this file are dedicated to the public domain.

#import "PFMoveApplication.h"

#import <Foundation/Foundation.h>
#include "CNUserNotification.h"
#import "NSString+SymlinksAndAliases.h"
#import <Security/Security.h>
#import <dlfcn.h>
#import <sys/param.h>
#import <sys/mount.h>
#import "../version.h"

// Helper functions
static NSString *PreferredInstallLocation(BOOL *isUserDirectory);
static NSString *ContainingDiskImageDevice();
static BOOL Trash(NSString *path);
static BOOL DeleteOrTrash(NSString *path);
static BOOL AuthorizedInstall(NSString *srcPath, NSString *dstPath, BOOL *canceled);
static BOOL CopyBundle(NSString *srcPath, NSString *dstPath);
static NSString *ShellQuotedString(NSString *string);
static void Relaunch(NSString *destinationPath);

// Main worker function
bool PFMoveToApplicationsFolderIfNecessary() {
	// Path of the bundle
	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	
	// File Manager
	NSFileManager *fm = [NSFileManager defaultManager];
	
    // Are we on a disk image?
    NSString *diskImageDevice = ContainingDiskImageDevice();
	
	// Since we are good to go, get the preferred installation directory.
	BOOL installToUserApplications = NO;
	NSString *applicationsDirectory = PreferredInstallLocation(&installToUserApplications);
	NSString *bundleName = [bundlePath lastPathComponent];
	NSString *destinationPath = [applicationsDirectory stringByAppendingPathComponent:bundleName];
	
	// Check if we need admin password to write to the Applications directory
	BOOL needAuthorization = ([fm isWritableFileAtPath:applicationsDirectory] == NO);
	
	// Check if the destination bundle is already there but not writable
	needAuthorization |= ([fm fileExistsAtPath:destinationPath] && ![fm isWritableFileAtPath:destinationPath]);
	
	
	// Activate app -- work-around for focus issues related to "scary file from internet" OS dialog.
	if (![NSApp isActive]) {
		[NSApp activateIgnoringOtherApps:YES];
	}
	
	NSLog(@"INFO -- Moving myself to the Applications folder");
	
	// Move
	if (needAuthorization) {
		BOOL authorizationCanceled;
		
		if (!AuthorizedInstall(bundlePath, destinationPath, &authorizationCanceled)) {
			if (authorizationCanceled) {
				NSLog(@"INFO -- Not moving because user canceled authorization");
				return false;
			}
			else {
				NSLog(@"ERROR -- Could not copy myself to /Applications with authorization");
				// Show failure message
				NSAlert* alert = [[NSAlert alloc] init];
				[alert setMessageText:@"Could not move to Applications folder"];
				[alert runModal];
				return false;
			}
		}
	}
	else {
		// If a copy already exists in the Applications folder, put it in the Trash
		if ([fm fileExistsAtPath:destinationPath]) {
			// But first, make sure that it's not running
			BOOL destinationIsRunning = NO;
			
			for (NSRunningApplication *runningApplication in [[NSWorkspace sharedWorkspace] runningApplications]) {
				NSString *executablePath = [[runningApplication executableURL] path];
				if ([executablePath hasPrefix:destinationPath]) {
					destinationIsRunning = YES;
					break;
				}
			}
			
			if (destinationIsRunning) {
				// Give the running app focus and terminate myself
				NSLog(@"INFO -- Switching to an already running version");
				[[NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:[NSArray arrayWithObject:destinationPath]] waitUntilExit];
				exit(0);
			}
			else {
				if (!Trash([applicationsDirectory stringByAppendingPathComponent:bundleName])) {
					// Show failure message
					NSAlert* alert = [[NSAlert alloc] init];
					[alert setMessageText:@"Could not move to Applications folder"];
					[alert runModal];
					return false;
				}
			}
		}
		
		if (!CopyBundle(bundlePath, destinationPath)) {
			NSLog(@"ERROR -- Could not copy myself to %@", destinationPath);
			// Show failure message
			NSAlert* alert = [[NSAlert alloc] init];
			[alert setMessageText:@"Could not move to Applications folder"];
			[alert runModal];
			return false;
		}
	}
	
	// Trash the original app. It's okay if this fails.
	// NOTE: This final delete does not work if the source bundle is in a network mounted volume.
	//       Calling rm or file manager's delete method doesn't work either. It's unlikely to happen
	//       but it'd be great if someone could fix this.
	if (!DeleteOrTrash(bundlePath)) {
		NSLog(@"WARNING -- Could not delete application after moving it to Applications folder");
	}
	
	// Relaunch.
	Relaunch(destinationPath);
	
	// Launched from within a disk image? -- unmount (if no files are open after 5 seconds,
	// otherwise leave it mounted).
	if (diskImageDevice != nil) {
		NSString *script = [NSString stringWithFormat:@"(/bin/sleep 5 && /usr/bin/hdiutil detach %@) &", ShellQuotedString(diskImageDevice)];
		[NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:[NSArray arrayWithObjects:@"-c", script, nil]];
	}
	
	return true;
}

#pragma mark -
#pragma mark Helper Functions

static NSString *PreferredInstallLocation(BOOL *isUserDirectory) {
	// Return the preferred install location.
	// Assume that if the user has a ~/Applications folder, they'd prefer their
	// applications to go there.
	
	NSFileManager *fm = [NSFileManager defaultManager];
	
	NSArray *userApplicationsDirs = NSSearchPathForDirectoriesInDomains(NSApplicationDirectory, NSUserDomainMask, YES);
	
	if ([userApplicationsDirs count] > 0) {
		NSString *userApplicationsDir = [userApplicationsDirs objectAtIndex:0];
		BOOL isDirectory;
		
		if ([fm fileExistsAtPath:userApplicationsDir isDirectory:&isDirectory] && isDirectory) {
			// User Applications directory exists. Get the directory contents.
			NSArray *contents = [fm contentsOfDirectoryAtPath:userApplicationsDir error:NULL];
			
			// Check if there is at least one ".app" inside the directory.
			for (NSString *contentsPath in contents) {
				if ([[contentsPath pathExtension] isEqualToString:@"app"]) {
					if (isUserDirectory) *isUserDirectory = YES;
					return [userApplicationsDir stringByResolvingSymlinksAndAliases];
				}
			}
		}
	}
	
	// No user Applications directory in use. Return the machine local Applications directory
	if (isUserDirectory) *isUserDirectory = NO;
	return [[NSSearchPathForDirectoriesInDomains(NSApplicationDirectory, NSLocalDomainMask, YES) lastObject] stringByResolvingSymlinksAndAliases];
}

BOOL IsInApplicationsFolder(NSString *path) {
	// Check all the normal Application directories
	NSEnumerator *e = [NSSearchPathForDirectoriesInDomains(NSApplicationDirectory, NSAllDomainsMask, YES) objectEnumerator];
	NSString *appDirPath = nil;
	
	while ((appDirPath = [e nextObject])) {
		if ([path hasPrefix:appDirPath]) return YES;
	}
	
	// Also, handle the case that the user has some other Application directory (perhaps on a separate data partition).
	if ([[path pathComponents] containsObject:@"Applications"]) {
		return YES;
	}
	
	return NO;
}

static NSString *ContainingDiskImageDevice() {
	NSString *containingPath = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
	
    struct statfs fs;
    if (statfs([containingPath fileSystemRepresentation], &fs) || (fs.f_flags & MNT_ROOTFS))
        return nil;
	
    NSString *device = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:fs.f_mntfromname length:strlen(fs.f_mntfromname)];
	
    NSTask *hdiutil = [[NSTask alloc] init];
    [hdiutil setLaunchPath:@"/usr/bin/hdiutil"];
    [hdiutil setArguments:[NSArray arrayWithObjects:@"info", @"-plist", nil]];
    [hdiutil setStandardOutput:[NSPipe pipe]];
    [hdiutil launch];
    [hdiutil waitUntilExit];
	
    NSData *data = [[[hdiutil standardOutput] fileHandleForReading] readDataToEndOfFile];
    id info = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![info isKindOfClass:[NSDictionary class]])
        return nil;
	
    id images = [info objectForKey:@"images"];
    if (![images isKindOfClass:[NSArray class]])
        return nil;
	
    for (id image in images) {
        if (![image isKindOfClass:[NSDictionary class]])
            return nil;
		
        id systemEntities = [image objectForKey:@"system-entities"];
        if (![systemEntities isKindOfClass:[NSArray class]])
            return nil;
		
        for (id systemEntity in systemEntities) {
            id devEntry = [systemEntity objectForKey:@"dev-entry"];
            if (![devEntry isKindOfClass:[NSString class]])
                return nil;
            if ([devEntry isEqualToString:device])
                return device;
        }
    }
	
    return nil;
}

static BOOL Trash(NSString *path) {
	if ([[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation
													 source:[path stringByDeletingLastPathComponent]
												destination:@""
													  files:[NSArray arrayWithObject:[path lastPathComponent]]
														tag:NULL]) {
		return YES;
	}
	else {
		NSLog(@"ERROR -- Could not trash '%@'", path);
		return NO;
	}
}

static BOOL DeleteOrTrash(NSString *path) {
    NSError *error;
	
    if ([[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
        return YES;
    }
    else {
        NSLog(@"WARNING -- Could not delete '%@': %@", path, [error localizedDescription]);
        return Trash(path);
    }
}

static BOOL AuthorizedInstall(NSString *srcPath, NSString *dstPath, BOOL *canceled) {
	if (canceled) *canceled = NO;
	
	// Make sure that the destination path is an app bundle. We're essentially running 'sudo rm -rf'
	// so we really don't want to fuck this up.
	if (![dstPath hasSuffix:@".app"]) return NO;
	
	// Do some more checks
	if ([[dstPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) return NO;
	if ([[srcPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) return NO;
	
	int pid, status;
	AuthorizationRef myAuthorizationRef;
	
	// Get the authorization
	OSStatus err = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &myAuthorizationRef);
	if (err != errAuthorizationSuccess) return NO;
	
	AuthorizationItem myItems = {kAuthorizationRightExecute, 0, NULL, 0};
	AuthorizationRights myRights = {1, &myItems};
	AuthorizationFlags myFlags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;
	
	err = AuthorizationCopyRights(myAuthorizationRef, &myRights, NULL, myFlags, NULL);
	if (err != errAuthorizationSuccess) {
		if (err == errAuthorizationCanceled && canceled)
			*canceled = YES;
		goto fail;
	}
	
	static OSStatus (*security_AuthorizationExecuteWithPrivileges)(AuthorizationRef authorization, const char *pathToTool,
																   AuthorizationFlags options, char * const *arguments,
																   FILE **communicationsPipe) = NULL;
	if (!security_AuthorizationExecuteWithPrivileges) {
		// On 10.7, AuthorizationExecuteWithPrivileges is deprecated. We want to still use it since there's no
		// good alternative (without requiring code signing). We'll look up the function through dyld and fail
		// if it is no longer accessible. If Apple removes the function entirely this will fail gracefully. If
		// they keep the function and throw some sort of exception, this won't fail gracefully, but that's a
		// risk we'll have to take for now.
		security_AuthorizationExecuteWithPrivileges = (OSStatus (*)(AuthorizationRef, const char *, AuthorizationFlags, char *const *, FILE **)) dlsym(RTLD_DEFAULT, "AuthorizationExecuteWithPrivileges");
	}
	if (!security_AuthorizationExecuteWithPrivileges) {
		goto fail;
	}
	
	// Delete the destination
	{
		char *args[] = {(char*)"-rf", (char *)[dstPath fileSystemRepresentation], NULL};
		err = security_AuthorizationExecuteWithPrivileges(myAuthorizationRef, "/bin/rm", kAuthorizationFlagDefaults, args, NULL);
		if (err != errAuthorizationSuccess) goto fail;
		
		// Wait until it's done
		pid = wait(&status);
		if (pid == -1 || !WIFEXITED(status)) goto fail; // We don't care about exit status as the destination most likely does not exist
	}
	
	// Copy
	{
		char *args[] = {(char*)"-pR", (char *)[srcPath fileSystemRepresentation], (char *)[dstPath fileSystemRepresentation], NULL};
		err = security_AuthorizationExecuteWithPrivileges(myAuthorizationRef, "/bin/cp", kAuthorizationFlagDefaults, args, NULL);
		if (err != errAuthorizationSuccess) goto fail;
		
		// Wait until it's done
		pid = wait(&status);
		if (pid == -1 || !WIFEXITED(status) || WEXITSTATUS(status)) goto fail;
	}
	
	AuthorizationFree(myAuthorizationRef, kAuthorizationFlagDefaults);
	return YES;
	
fail:
	AuthorizationFree(myAuthorizationRef, kAuthorizationFlagDefaults);
	return NO;
}

static BOOL CopyBundle(NSString *srcPath, NSString *dstPath) {
	NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if ([fm copyItemAtPath:srcPath toPath:dstPath error:&error]) {
        return YES;
    }
    else {
        NSLog(@"ERROR -- Could not copy '%@' to '%@' (%@)", srcPath, dstPath, error);
    }
	return NO;
}

static NSString *ShellQuotedString(NSString *string) {
    return [NSString stringWithFormat:@"'%@'", [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static void Relaunch(NSString *destinationPath) {
	// The shell script waits until the original app process terminates.
	// This is done so that the relaunched app opens as the front-most app.
	int pid = [[NSProcessInfo processInfo] processIdentifier];
	
	// Command run just before running open /final/path
	NSString *preOpenCmd = @"";
	
    NSString *quotedDestinationPath = ShellQuotedString(destinationPath);
	
	// Before we launch the new app, clear xattr:com.apple.quarantine to avoid
	// duplicate "scary file from the internet" dialog.
    // Add the -r flag on 10.6
    preOpenCmd = [NSString stringWithFormat:@"/usr/bin/xattr -d -r com.apple.quarantine %@;", quotedDestinationPath];
	
	NSString *script = [NSString stringWithFormat:@"(while /bin/kill -0 %d >&/dev/null; do /bin/sleep 0.1; done; %@ /usr/bin/open %@) &", pid, preOpenCmd, quotedDestinationPath];
	[NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:[NSArray arrayWithObjects:@"-c", script, nil]];
}