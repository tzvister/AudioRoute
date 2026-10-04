/* Unprivileged system-domain XPC broker. Runs as _coreaudiod, outside the HAL
 * sandbox. Serves only HAL peers under that same uid, never accepts paths. */
#include <xpc/xpc.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pwd.h>
#include "VirtualAudioTransport.h"
static bool validID(const char *s){if(!s||!*s)return false;for(;*s;++s)if(!((*s>='a'&&*s<='z')||(*s>='0'&&*s<='9')||*s=='-'))return false;return true;}
static int number(CFDictionaryRef d,CFStringRef key){int n=0;CFTypeRef v=CFDictionaryGetValue(d,key);if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberIntType,&n);return n;}
static void answer(xpc_connection_t peer,xpc_object_t message) {
    if(xpc_get_type(message)!=XPC_TYPE_DICTIONARY)return;
    xpc_object_t reply=xpc_dictionary_create_reply(message);if(!reply)return;
    int fd=open(AR_SHARED_DIRECTORY "/registry.plist",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;CFDataRef data=NULL;CFPropertyListRef plist=NULL;
    if(fd>=0&&!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_size>0&&st.st_size<=1024*1024){
        UInt8 *b=malloc(st.st_size);if(b){ssize_t n=read(fd,b,st.st_size);if(n==st.st_size)data=CFDataCreate(NULL,b,n);free(b);}
    }
    if(fd>=0)close(fd);
    if(data)plist=CFPropertyListCreateWithData(NULL,data,kCFPropertyListImmutable,NULL,NULL);
    if(plist&&CFGetTypeID(plist)==CFDictionaryGetTypeID()) {
        CFTypeRef list=CFDictionaryGetValue(plist,CFSTR("devices"));
        if(list&&CFGetTypeID(list)==CFArrayGetTypeID()) {
            xpc_dictionary_set_data(reply,"registry",CFDataGetBytePtr(data),CFDataGetLength(data));
            xpc_object_t handles=xpc_dictionary_create(NULL,NULL,0);
            for(CFIndex i=0;i<CFArrayGetCount(list);++i) {
                CFTypeRef d=CFArrayGetValueAtIndex(list,i);if(CFGetTypeID(d)!=CFDictionaryGetTypeID())continue;
                CFTypeRef id=CFDictionaryGetValue(d,CFSTR("id"));char identifier[128];
                if(!id||CFGetTypeID(id)!=CFStringGetTypeID()||!CFStringGetCString(id,identifier,sizeof(identifier),kCFStringEncodingUTF8)||!validID(identifier))continue;
                char path[512];snprintf(path,sizeof(path),AR_SHARED_DIRECTORY "/devices/%s.shm",identifier);
                ar_transport *t=ar_transport_open(path,number(d,CFSTR("inputChannels")),number(d,CFSTR("outputChannels")),0);
                if(t){xpc_object_t region=ar_transport_export_shared_memory(t);if(region){xpc_dictionary_set_value(handles,identifier,region);xpc_release(region);}ar_transport_close(t);}
            }
            xpc_dictionary_set_value(reply,"handles",handles);xpc_release(handles);
        }
    }
    if(plist)CFRelease(plist);if(data)CFRelease(data);
    xpc_connection_send_message(peer,reply);xpc_release(reply);
}
int main(void) {
    struct passwd *account=getpwnam("_coreaudiod");if(!account||geteuid()!=account->pw_uid){fputs("AudioRoute broker must run as _coreaudiod.\n",stderr);return 1;}
    uid_t allowed=account->pw_uid;
    dispatch_queue_t queue=dispatch_queue_create("org.audioroute.transport",DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener=xpc_connection_create_mach_service("org.audioroute.transport",queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if(!listener)return 1;
    xpc_connection_set_event_handler(listener,^(xpc_object_t event){
        if(xpc_get_type(event)!=XPC_TYPE_CONNECTION)return;
        xpc_connection_t peer=event;
        if(xpc_connection_get_euid(peer)!=allowed){xpc_connection_cancel(peer);return;}
        xpc_connection_set_target_queue(peer,queue);
        xpc_connection_set_event_handler(peer,^(xpc_object_t message){answer(peer,message);});xpc_connection_resume(peer);
    });xpc_connection_resume(listener);dispatch_main();
}
