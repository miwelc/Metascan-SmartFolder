//
//  monitor.c
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 17/10/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//


#include "monitor.h"

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <errno.h>
#include <string.h>
#include <inttypes.h>

#define MAX_EVENTS 100

char *flagstring(int flags);

bool Monitor::finish = false;
unordered_map<string, Monitor::FileInfo> Monitor::filesMonitored;
int Monitor::kq;

void Monitor::cleanUp() {
	for(auto it = filesMonitored.begin(); it != filesMonitored.end();) {
		close((*it).second.fd);
		it = filesMonitored.erase(it); //increments iterator
	}
}

void Monitor::removeEvents(string path) {
	if(filesMonitored.find(path) != filesMonitored.end()) { //If is currently being monitored
		bool isFolder = filesMonitored[path].isFolder;
		close(filesMonitored[path].fd);
		filesMonitored.erase(path);
		
		//Tell the scanner the file was deleted
		Scanner::fileDeleted(path);
		
		//Propagate removal in case it was a folder
		if(isFolder) {
			path += "/";
			for(auto it = filesMonitored.begin(); it != filesMonitored.end();) {
				if(it->first.find(path) == 0) {
					printf("Deleted '%s'\n", it->first.c_str());
					close(it->second.fd);
					//Tell the scanner the file was deleted
					Scanner::fileDeleted(it->first.c_str());
					it = filesMonitored.erase(it); //increments it
				} else
					it++;
			}
		}
	}
}

bool Monitor::addEventListener(string path) {
	struct kevent kev;
	struct stat fileProperties;
	bool newFile = false;
	
	lstat(path.c_str(), &fileProperties);
	
	//If filename is exactly ".DS_Store" omit it
	if(!S_ISDIR(fileProperties.st_mode) && path.substr(path.find_last_of("/")+1).compare(".DS_Store") == 0)
		return false;
	
	if(filesMonitored.find(path) == filesMonitored.end()) { //if it doesn't already exists, we add it
		if((filesMonitored[path].fd = open(path.c_str(), O_EVTONLY)) == -1) {
            fprintf(stderr, "The file/directory %s could not be opened for monitoring.  Error was %s.\n", path.c_str(), strerror(errno));
			filesMonitored.erase(path.c_str());
			return false;
        }
		filesMonitored[path].path = path;
		filesMonitored[path].isFolder = S_ISDIR(fileProperties.st_mode);
		
		printf("Added %s\n", path.c_str());
		newFile = true;
	
		//Create the kevent
		kev.ident = filesMonitored[path].fd;
		kev.flags = EV_ADD | EV_CLEAR;
		kev.filter = EVFILT_VNODE;
		kev.fflags = NOTE_DELETE|NOTE_WRITE|NOTE_EXTEND|NOTE_ATTRIB|NOTE_LINK|NOTE_RENAME|NOTE_REVOKE;
		kev.data = 0;
		kev.udata = (void*)filesMonitored[path].path.c_str();
		
		kevent(kq, &kev, 1, 0, 0, 0);
	}
	
	return newFile;
}

void Monitor::reIndex(string pathBase) {
	DIR *pdir;
	struct dirent *pdent;
	
    if ((pdir = opendir(pathBase.c_str())) == NULL) {
        fprintf(stderr, "Directory can not be opened: %s\n", pathBase.c_str());
		return;
	}
	
    //Skip . and .. entries
    readdir(pdir);
    readdir(pdir);
	
    //For each directory entry create a kevent structure.
    while((pdent = readdir(pdir)) != NULL) {
		bool isNewFile;
		struct stat fileProperties;
		string path = pathBase;
		path += "/";
		path += pdent->d_name;
		
		isNewFile = addEventListener(path);

		if(isNewFile) {
			lstat(path.c_str(), &fileProperties);
			if(S_ISDIR(fileProperties.st_mode)) //If it's a new folder, keep indexing subfolders
				reIndex(path);
			else if(fileProperties.st_size < 80*1024*1024) { //It's a new file, we have to scan it (ONLY IF < 80MB)
				Scanner::scanFile(path);
			}
		}
    }
	
	closedir(pdir);
}

Monitor::Monitor() {
	finish = false;
}

Monitor::~Monitor() {
	cleanUp();
}

void* Monitor::startMonitoring(void* _path) {
	struct kevent eventsTriggered[MAX_EVENTS];
	string path = (char*)_path;
	
    //Open a kernel queue
    if((kq = kqueue()) < 0) {
        fprintf(stderr, "Could not open kernel queue.  Error was %s.\n", strerror(errno));
    }
	
    //Initialize a kevent for base dir
	addEventListener(path);
	//Index base folder
	reIndex(path);
	
    struct timespec timeout;
    while(!finish) {
		timeout.tv_sec = 1;
		timeout.tv_nsec = 0;
		
        int event_count = kevent(kq, 0, 0, eventsTriggered, MAX_EVENTS, &timeout);
		
        for(int i = 0; i < event_count; i++) {
			if (eventsTriggered[i].flags == EV_ERROR) {
				fprintf(stderr, "An error occurred (event count %d).  The error was %s.\n", event_count, strerror(errno));
				continue;
			}
			if((eventsTriggered[i].fflags & NOTE_WRITE)
			|| (eventsTriggered[i].fflags & NOTE_EXTEND)) {
				struct stat fileProperties;
				lstat((char*)eventsTriggered[i].udata, &fileProperties);
				if(S_ISDIR(fileProperties.st_mode) && (eventsTriggered[i].fflags & NOTE_LINK) == false) {
					printf("Some file has been modified in %s\n", eventsTriggered[i].udata);
					reIndex((char*)eventsTriggered[i].udata);
				}
				else if(!S_ISDIR(fileProperties.st_mode)) {
					printf("File '%s' changed\n", eventsTriggered[i].udata);
					
				}
			}
			if(eventsTriggered[i].fflags & NOTE_LINK) { //Added a new file/folder
				struct stat fileProperties;
				lstat((char*)eventsTriggered[i].udata, &fileProperties);
				if(S_ISDIR(fileProperties.st_mode)) {
					printf("Number of files changed, reindexing %s\n", eventsTriggered[i].udata);
					reIndex((char*)eventsTriggered[i].udata);
				}
			}
			if(eventsTriggered[i].fflags & NOTE_RENAME) {
				string path = (char*)eventsTriggered[i].udata;
				printf("File '%s' renamed/deleted\n", path.c_str());
                //Delete old name
				removeEvents(path.c_str());
				//Reindex the containing folder
				reIndex(path.substr(0, path.find_last_of("/")));
			}
			if(eventsTriggered[i].fflags & NOTE_DELETE) {
				//try to add it again in case its been just modified
				printf("File/folder %s deleted\n", eventsTriggered[i].udata);
				removeEvents((char*)eventsTriggered[i].udata);
			}

			
           /* printf("Event %" PRIdPTR " occurred.  Filter %d, flags %d, filter flags %s, filter data %" PRIdPTR ", path %s\n",
				   eventsTriggered[i].ident,
				   eventsTriggered[i].filter,
				   eventsTriggered[i].flags,
				   flagstring(eventsTriggered[i].fflags),
				   eventsTriggered[i].data,
				   (char *)eventsTriggered[i].udata);
			*/
        }
		if(event_count == 0) printf("No event.\n");
    }
	
	printf("Finishing monitor thread...\n");
	cleanUp();
	finish = false;
	
    return NULL;
}

/* A simple routine to return a string for a set of flags. */
char *flagstring(int flags)
{
    static char ret[512];
	
    ret[0]='\0'; // clear the string.
    if (flags & NOTE_DELETE) {strcat(ret,"NOTE_DELETE|");}
    if (flags & NOTE_WRITE) {strcat(ret,"NOTE_WRITE|");}
    if (flags & NOTE_EXTEND) {strcat(ret,"NOTE_EXTEND|");}
    if (flags & NOTE_ATTRIB) {strcat(ret,"NOTE_ATTRIB|");}
    if (flags & NOTE_LINK) {strcat(ret,"NOTE_LINK|");}
    if (flags & NOTE_RENAME) {strcat(ret,"NOTE_RENAME|");}
    if (flags & NOTE_REVOKE) {strcat(ret,"NOTE_REVOKE|");}
	
    return ret;
}
