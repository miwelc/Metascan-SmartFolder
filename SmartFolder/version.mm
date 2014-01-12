//
//  version.c
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 02/11/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//
#include <Cocoa/Cocoa.h>

int getMACOSXversion() {
	int macVersion;
    if(Gestalt(gestaltSystemVersion, &macVersion) == noErr)
        return macVersion;
	else
		return MAC_OS_X_VERSION_10_0;
}

int runningMLOrLater() {
	return getMACOSXversion() > MAC_OS_X_VERSION_10_7;
}