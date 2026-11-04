import Foundation

func require(_ condition: Bool, _ line: Int = #line) {
    if !condition {
        print("failed at line \(line)")
        exit(1)
    }
}

let parent = "/var/containers/Bundle/Application"
// 0x01 ^ 0x23 ^ 0x45 ^ 0x67 ^ 0x89 ^ 0xAB ^ 0xCD == 0xEF
require(RoothideRoot.containing(parent + "/.jbroot-0123456789ABCDEF/Applications/Example.app")
    == parent + "/.jbroot-0123456789ABCDEF")
require(RoothideRoot.containing("/private" + parent + "/.jbroot-0123456789abcdef/usr/libexec/exampled")
    == "/private" + parent + "/.jbroot-0123456789abcdef")

for path in [
    "/var/jb/Applications/Example.app",
    "/private/preboot/hash/dopamine/procursus/Applications/Example.app",
    parent + "/.jbroot-0123456789ABCDEE/Applications/Example.app",
    parent + "/.jbroot-test/Applications/Example.app",
    parent + "/.jbroot-+123456789ABCDEF/Applications/Example.app",
    "/var/jb/Applications/Example.app/.jbroot/Applications/Example.app",
    "",
] {
    require(RoothideRoot.containing(path) == nil)
}

/// Mobile's home, where the package makes the data folder and the session
/// host's workers keep it. Launched as rootless uicache launches an app with
/// no `no-container`: HOME and CFFIXED_USER_HOME name its data container, so
/// the process's own home is not mobile's (issue #37).
let container = "/private/var/mobile/Containers/Data/Application/0F1E2D3C-0000-4000-8000-000000000000"
setenv("CFFIXED_USER_HOME", container, 1)
setenv("HOME", container, 1)
require(NSHomeDirectory() == container)
require(RoothideRoot.mobileHome(for: parent + "/.jbroot-0123456789ABCDEF/Applications/Apelin.app")
    == parent + "/.jbroot-0123456789ABCDEF/var/mobile")
require(RoothideRoot.mobileHome(for: "/private" + parent + "/.jbroot-0123456789abcdef/usr/libexec/apelind")
    == "/private" + parent + "/.jbroot-0123456789abcdef/var/mobile")
for path in [
    "/var/jb/Applications/Apelin.app",
    "/private/preboot/hash/dopamine/procursus/Applications/Apelin.app",
    "/private/preboot/hash/dopamine/procursus/usr/libexec/apelind",
] {
    require(RoothideRoot.mobileHome(for: path) == "/var/mobile")
}
