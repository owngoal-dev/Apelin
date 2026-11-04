// Prints, for each Apple class named on the command line, every selector its
// superclass chain answers, from the Objective-C runtime of a Mac Catalyst
// process: instance and class methods of each class up to the root, private
// ones and every category the loaded frameworks add included, and the
// protocols each class adopts with their optional selectors. Catalyst's
// UIKitCore is iOS UIKit's, private methods and all, closely enough to find
// a selector of ours that would take one over. audit-objc-selectors.sh builds
// and runs it; it sends no message to any class, so nothing is initialized.
//
//   S  <class> <superclass or ->      I  <class> <instance selector>
//   C  <class> <class selector>       P  <class> <adopted protocol>
//   PP <protocol> <parent protocol>   PO <protocol> <i|c> <optional selector>
//   MISSING <class>                   UNLOADED <library>
//
// An argument that starts with `+` is a library the audited binaries link,
// loaded first (its Catalyst copy under /System/iOSSupport when there is
// one), so the categories it adds to NSObject or UIView are counted too.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSMutableSet<NSString *> *printedClasses;
static NSMutableSet<NSString *> *printedProtocols;

static void printMethods(Class cls, const char *kind, const char *name) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count; index++) {
        printf("%s\t%s\t%s\n", kind, name, sel_getName(method_getName(methods[index])));
    }
    free(methods);
}

static void printProtocol(Protocol *protocol) {
    NSString *name = @(protocol_getName(protocol));
    if ([printedProtocols containsObject:name]) return;
    [printedProtocols addObject:name];
    for (int instance = 0; instance < 2; instance++) {
        unsigned int count = 0;
        struct objc_method_description *descriptions = protocol_copyMethodDescriptionList(protocol, NO, instance, &count);
        for (unsigned int index = 0; index < count; index++) {
            printf("PO\t%s\t%s\t%s\n", name.UTF8String, instance ? "i" : "c", sel_getName(descriptions[index].name));
        }
        free(descriptions);
    }
    unsigned int count = 0;
    Protocol *__unsafe_unretained *parents = protocol_copyProtocolList(protocol, &count);
    for (unsigned int index = 0; index < count; index++) {
        printf("PP\t%s\t%s\n", name.UTF8String, protocol_getName(parents[index]));
        printProtocol(parents[index]);
    }
    free(parents);
}

static void printClass(Class cls) {
    while (cls) {
        NSString *name = @(class_getName(cls));
        if ([printedClasses containsObject:name]) return;
        [printedClasses addObject:name];
        Class superclass = class_getSuperclass(cls);
        printf("S\t%s\t%s\n", name.UTF8String, superclass ? class_getName(superclass) : "-");
        printMethods(cls, "I", name.UTF8String);
        printMethods(object_getClass(cls), "C", name.UTF8String);
        unsigned int count = 0;
        Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            printf("P\t%s\t%s\n", name.UTF8String, protocol_getName(protocols[index]));
            printProtocol(protocols[index]);
        }
        free(protocols);
        cls = superclass;
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        printedClasses = [NSMutableSet set];
        printedProtocols = [NSMutableSet set];
        // Swift's root class, for Apelin's classes that inherit from no NSObject.
        dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOW);
        for (int index = 1; index < argc; index++) {
            if (argv[index][0] != '+') continue;
            const char *path = argv[index] + 1;
            NSString *catalyst = [@"/System/iOSSupport" stringByAppendingString:@(path)];
            if (!dlopen(catalyst.fileSystemRepresentation, RTLD_NOW) && !dlopen(path, RTLD_NOW)) {
                printf("UNLOADED\t%s\n", path);
            }
        }
        for (int index = 1; index < argc; index++) {
            if (argv[index][0] == '+') continue;
            Class cls = objc_getClass(argv[index]);
            if (cls) {
                printClass(cls);
            } else {
                printf("MISSING\t%s\n", argv[index]);
            }
        }
    }
    return 0;
}
