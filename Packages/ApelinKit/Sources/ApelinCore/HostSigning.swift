import Darwin

/// Whether this device runs the code Apelin signs. Everything Apelin makes
/// is signed ad hoc — `ApelinCodeSign` writes what `ldid -S` writes, for the
/// retargeted toolchain, its self-tests and every build's products alike —
/// and is installed through irisind, not dpkg. A jailbreak with a kernel
/// exploit runs those: Dopamine-roothide, for one, puts each binary in the
/// trust cache as it is spawned (systemhook's `jbclient_trust_file_by_path`).
///
/// roothide's Bootstrap, the TrollStore one, trusts nothing that way. It
/// runs only a signature CoreTrust accepts through CVE-2023-41991,
/// TrollStore's bug, which the iOS 15.0–17.0 it supports still have, and
/// writes that signature itself, from a hook on dpkg's `close()` that runs
/// its own `ldid` and then `fastPathSign` over every Mach-O dpkg unpacks
/// (Bootstrap-basebin, `bootstrap/autosign.m`). An ad hoc signature is
/// killed at launch there, and nothing Apelin installs passes through that
/// hook: on issue #35's iPhone the toolchain's clang was "Bad executable"
/// at its self-test, and a bootstrap `/bin/echo` signed again with
/// `ldid -S` was SIGKILLed.
///
/// Bootstrap marks the root it makes with `.thebootstrapped`
/// (`.bootstrapped` in its betas), and goes by that mark to tell its own
/// root from another (`isBootstrapInstalled`, Bootstrap/bootstrap.m);
/// Dopamine-roothide refuses to jailbreak over a root that has it and
/// marks its own `.installed_dopamine` (DOBootstrapper.m), so the mark is
/// never Dopamine's.
public enum HostSigning {
    static let bootstrapMarks = [".thebootstrapped", ".bootstrapped"]

    /// Shown wherever a toolchain would be set up, imported or built with on
    /// roothide Bootstrap. The app's catalogue has it as a key, so an alert
    /// showing it reads it in the user's language: change both together.
    public static let bootstrapRefusal = "Apelin cannot build on roothide Bootstrap. Bootstrap runs only programs it signs itself, and it does not sign Apelin’s build tools or the programs they build."

    /// Whether `installRoot` is a root roothide Bootstrap made: a root named
    /// as libroothide names one, holding Bootstrap's mark as a regular file.
    public static func isRoothideBootstrap(installRoot: String) -> Bool {
        guard let root = CanonicalPath.resolve(installRoot),
              let name = CanonicalPath.components(root).last,
              BootstrapRootPath.isRootName(name)
        else { return false }
        return bootstrapMarks.contains { mark in
            var metadata = stat()
            return lstat(root + "/" + mark, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
        }
    }

    /// Why Apelin's toolchain, and so anything it would build, cannot run
    /// under `installRoot`; nil when it can.
    public static func toolchainRefusal(installRoot: String) -> String? {
        isRoothideBootstrap(installRoot: installRoot) ? bootstrapRefusal : nil
    }
}
