//
//  Header.h
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 17/10/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#ifndef SmartFolder_monitor_h
#define SmartFolder_monitor_h

#include <unordered_map>
#include <string>
#include "scanner.h"

using namespace std;

class Monitor {
	private:
		static bool finish;
	
		struct FileInfo {
			int fd;
			string path;
			bool isFolder;
		};
		static unordered_map<string, FileInfo> filesMonitored; //Indexed by path
		//Kqueue
		static int kq;
	
		static void cleanUp();
		static void removeEvents(string path);
		static bool addEventListener(string path);
		static void reIndex(string pathBase);
	
	public:
		Monitor();
		~Monitor();
		static void* startMonitoring(void* _path);
		static void endMonitoring() { finish = true; };
};

#endif
