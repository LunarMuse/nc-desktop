/*
 * SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

import ArgumentParser
import Foundation

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Client building script")

    @Argument(help: "Path to the root directory of the Nextcloud Desktop Client git repository.")
    var repoRootDir = "\(FileManager.default.currentDirectoryPath)/../../.."

    @Option(name: [.short, .long], help: "Code signing identity for desktop client and libs.")
    var codeSignIdentity: String?

    @Option(name: [.short, .long], help: "Path for build files to be written.")
    var buildPath = "\(FileManager.default.currentDirectoryPath)/build"

    @Option(name: [.short, .long], help: "Path for the final product to be put.")
    var productPath = "\(FileManager.default.currentDirectoryPath)/product"

    @Option(name: [.short, .long], help: "Architecture.")
    var arch = "arm64"

    @Option(name: [.long], help: "Brew installation script URL.")
    var brewInstallShUrl = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    @Option(name: [.long], help: "CraftMaster Git URL.")
    var craftMasterGitUrl = "https://invent.kde.org/ggadinger/craftmaster.git"

    @Option(name: [.long], help: "KDE Craft blueprints Git URL.")
    var kdeBlueprintsGitUrl = "https://github.com/nextcloud/craft-blueprints-kde.git"

    @Option(name: [.long], help: "KDE Craft blueprints git ref/branch")
    var kdeBlueprintsGitRef = "stable-3.17"

    @Option(name: [.long], help: "Nextcloud Desktop Client craft blueprints Git URL.")
    var clientBlueprintsGitUrl = "https://github.com/nextcloud/desktop-client-blueprints.git"

    @Option(name: [.long], help: "Nextcloud Desktop Client craft blueprints Git ref/branch.")
    var clientBlueprintsGitRef = "stable-3.17"

    @Option(name: [.long], help: "Nextcloud Desktop Client craft blueprint name.")
    var craftBlueprintName = "nextcloud-client"

    @Option(name: [.long], help: "Build type (e.g. Release, RelWithDebInfo, MinSizeRel, Debug).")
    var buildType = "RelWithDebInfo"

    @Option(name: [.long], help: "The application's branded name.")
    var appName = "Nextcloud"

    @Option(name: [.long], help: "Sparkle download URL.")
    var sparkleDownloadUrl =
        "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz"

    @Option(name: [.long], help: "Git clone command; include options such as depth.")
    var gitCloneCommand = "git clone --depth=1"

    @Option(name: [.long], help: "Apple ID, used for notarisation.")
    var appleId: String?

    @Option(name: [.long], help: "Apple ID password, used for notarisation.")
    var applePassword: String?

    @Option(name: [.long], help: "Apple Team ID, used for notarisation.")
    var appleTeamId: String?

    @Option(name: [.long], help: "Apple package signing ID.")
    var packageSigningId: String?

    @Option(name: [.long], help: "Sparkle package signing key.")
    var sparklePackageSignKey: String?

    @Option(name: [.long], help: "Override server URL.")
    var overrideServerUrl: String?

    @Flag(help: "Reconfigure KDE Craft.")
    var reconfigureCraft = false

    @Flag(help: "Run build offline (i.e. do not update craft)")
    var offline = false

    @Flag(help: "Build test suite.")
    var buildTests = false

    @Flag(name: [.long], help: "Do not build App Bundle.")
    var disableAppBundle = false

    @Flag(help: "Build File Provider Module.")
    var buildFileProviderModule = false

    @Flag(help: "Build without Sparkle auto-updater.")
    var disableAutoUpdater = false

    @Flag(help: "Run a full rebuild.")
    var fullRebuild = false

    @Flag(help: "Force override server URL.")
    var forceOverrideServerUrl = false

    @Flag(help: "Create an installer package.")
    var package = false

    @Flag(help: "Build in developer mode.")
    var dev = false

    mutating func run() throws {
        print("Configuring build tooling.")

        if codeSignIdentity != nil {
            guard commandExists("codesign") else {
                throw MacCrafterError.environmentError("codesign not found, cannot proceed.")
            }
        }

        try installIfMissing("git", "xcode-select --install")
        try installIfMissing(
            "brew",
            "curl -fsSL \(brewInstallShUrl) | /bin/bash",
            installCommandEnv: ["NONINTERACTIVE": "1"]
        )
        try installIfMissing("wget", "brew install wget")
        try installIfMissing("inkscape", "brew install inkscape")
        try installIfMissing("python3", "brew install pyenv && pyenv install 3.12.4")

        print("Build tooling configured.")

        let fm = FileManager.default
        let craftMasterDir = "\(buildPath)/craftmaster"
        let craftMasterIni = "\(repoRootDir)/craftmaster.ini"
        let craftMasterPy = "\(craftMasterDir)/CraftMaster.py"
        let craftTarget = archToCraftTarget(arch)
        let craftCommand =
            "python3 \(craftMasterPy) --config \(craftMasterIni) --target \(craftTarget) -c"

        if !fm.fileExists(atPath: craftMasterDir) || reconfigureCraft {
            print("Configuring KDE Craft.")

            if fm.fileExists(atPath: craftMasterDir) {
                print("KDE Craft is already cloned.")
            } else {
                print("Cloning KDE Craft...")
                guard shell("\(gitCloneCommand) \(craftMasterGitUrl) \(craftMasterDir)") == 0 else {
                    throw MacCrafterError.gitError("The referenced CraftMaster repository could not be cloned.")
                }
            }

            print("Configuring required KDE Craft blueprint repositories...")
            guard shell("\(craftCommand) --add-blueprint-repository '\(kdeBlueprintsGitUrl)|\(kdeBlueprintsGitRef)|'") == 0 else {
                throw MacCrafterError.craftError("Error adding KDE blueprint repository.")
            }
            guard shell("\(craftCommand) --add-blueprint-repository '\(clientBlueprintsGitUrl)|\(clientBlueprintsGitRef)|'") == 0 else {
                throw MacCrafterError.craftError("Error adding Nextcloud Client blueprint repository.")
            }

            print("Crafting KDE Craft...")
            guard shell("\(craftCommand) craft") == 0 else {
                throw MacCrafterError.craftError("Error crafting KDE Craft.")
            }

            print("Crafting Nextcloud Desktop Client dependencies...")
            guard shell("\(craftCommand) --install-deps \(craftBlueprintName)") == 0 else {
                throw MacCrafterError.craftError("Error installing dependencies.")
            }
        }

        var craftOptions = [
            "\(craftBlueprintName).srcDir=\(repoRootDir)",
            "\(craftBlueprintName).osxArchs=\(arch)",
            "\(craftBlueprintName).buildTests=\(buildTests ? "True" : "False")",
            "\(craftBlueprintName).buildMacOSBundle=\(disableAppBundle ? "False" : "True")",
            "\(craftBlueprintName).buildFileProviderModule=\(buildFileProviderModule ? "True" : "False")"
        ]

        if let overrideServerUrl {
            craftOptions.append("\(craftBlueprintName).overrideServerUrl=\(overrideServerUrl)")
            craftOptions.append("\(craftBlueprintName).forceOverrideServerUrl=\(forceOverrideServerUrl ? "True" : "False")")
        }

        if dev {
            appName += "Dev"
            craftOptions.append("\(craftBlueprintName).devMode=True")
        }

        if !disableAutoUpdater {
            print("Configuring Sparkle auto-updater.")

            let fm = FileManager.default
            guard fm.fileExists(atPath: "\(buildPath)/Sparkle.tar.xz") ||
                  shell("wget \(sparkleDownloadUrl) -O \(buildPath)/Sparkle.tar.xz") == 0
            else {
                throw MacCrafterError.environmentError("Error downloading sparkle.")
            }

            guard fm.fileExists(atPath: "\(buildPath)/Sparkle.framework") ||
                  shell("tar -xvf \(buildPath)/Sparkle.tar.xz -C \(buildPath)") == 0
            else {
                throw MacCrafterError.environmentError("Error unpacking sparkle.")
            }

            craftOptions.append(
                "\(craftBlueprintName).sparkleLibPath=\(buildPath)/Sparkle.framework"
            )
        }

        let clientBuildDir = "\(buildPath)/\(craftTarget)/build/\(craftBlueprintName)"
        print("Crafting \(appName) Desktop Client...")
        if fullRebuild {
            do {
                try fm.removeItem(atPath: clientBuildDir)
            } catch let error {
                print("WARNING! Error removing build directory: \(error)")
            }
        } else {
            // HACK: When building the client we often run into issues with the shell integration
            // component -- particularly the FileProviderExt part. So we wipe out the build
            // artifacts so this part gets build first. Let's first check if we have an existing
            // build in the folder we expect
            let shellIntegrationDir = "\(clientBuildDir)/work/build/shell_integration/MacOSX"
            if fm.fileExists(atPath: shellIntegrationDir) {
                print("Removing existing shell integration build artifacts...")
                do {
                    try fm.removeItem(atPath: shellIntegrationDir)
                } catch let error {
                    print("WARNING! Error removing shell integration build directory: \(error)")
                }
            }
        }

        let buildMode = fullRebuild ? "-i" : disableAppBundle ? "compile" : "--compile --install"
        let offlineMode = offline ? "--offline" : ""
        let allOptionsString = craftOptions.map({ "--options \"\($0)\"" }).joined(separator: " ")
        guard shell(
            "\(craftCommand) --buildtype \(buildType) \(buildMode) \(offlineMode) \(allOptionsString) \(craftBlueprintName)"
        ) == 0 else {
            // Troubleshooting: This can happen because a CraftMaster repository was cloned which does not contain the commit defined in craftmaster.ini of this project due to use of customized forks.
            throw MacCrafterError.craftError("Error crafting Nextcloud Desktop Client.")
        }

        let clientAppDir = "\(clientBuildDir)/image-\(buildType)-master/\(appName).app"
        if let codeSignIdentity {
            print("Code-signing Nextcloud Desktop Client libraries and frameworks...")
            let entitlementsPath = "\(clientBuildDir)/work/build/admin/osx/macosx.entitlements"
            try codesignClientAppBundle(
                at: clientAppDir,
                withCodeSignIdentity: codeSignIdentity,
                usingEntitlements: entitlementsPath
            )
        }

        print("Placing Nextcloud Desktop Client in \(productPath)...")
        if !fm.fileExists(atPath: productPath) {
            try fm.createDirectory(
                atPath: productPath, withIntermediateDirectories: true, attributes: nil
            )
        }
        if fm.fileExists(atPath: "\(productPath)/\(appName).app") {
            try fm.removeItem(atPath: "\(productPath)/\(appName).app")
        }
        try fm.copyItem(atPath: clientAppDir, toPath: "\(productPath)/\(appName).app")

        if package {
            try packageAppBundle(
                productPath: productPath,
                buildPath: buildPath,
                craftTarget: craftTarget,
                craftBlueprintName: craftBlueprintName,
                appName: appName,
                packageSigningId: packageSigningId,
                appleId: appleId,
                applePassword: applePassword,
                appleTeamId: appleTeamId,
                sparklePackageSignKey: sparklePackageSignKey
            )
        }

        print("Done!")
    }
}

struct Codesign: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Codesigning script for the client.")

    @Argument(help: "Path to the Nextcloud Desktop Client app bundle.")
    var appBundlePath = "\(FileManager.default.currentDirectoryPath)/product/Nextcloud.app"

    @Option(name: [.short, .long], help: "Code signing identity for desktop client and libs.")
    var codeSignIdentity: String

    @Option(name: [.short, .long], help: "Entitlements to apply to the app bundle.")
    var entitlementsPath: String?

    mutating func run() throws {
        let absolutePath = appBundlePath.hasPrefix("/")
            ? appBundlePath
            : "\(FileManager.default.currentDirectoryPath)/\(appBundlePath)"

        try codesignClientAppBundle(
            at: absolutePath,
            withCodeSignIdentity: codeSignIdentity,
            usingEntitlements: entitlementsPath
        )
    }
}

struct CreateDMG: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Creae a DMG for the client.")

    @Argument(help: "Path to the desktop client app bundle.")
    var appBundlePath: String

    @Option(name: [.short, .long], help: "Path for the final product to be put.")
    var productPath = "\(FileManager.default.currentDirectoryPath)/product"

    @Option(name: [.short, .long], help: "Path for build files to be written.")
    var buildPath = "\(FileManager.default.currentDirectoryPath)/build"

    @Option(name: [.long], help: "The application's branded name.")
    var appName = "Nextcloud"

    @Option(name: [.long], help: "Apple ID, used for notarisation.")
    var appleId: String?

    @Option(name: [.long], help: "Apple ID password, used for notarisation.")
    var applePassword: String?

    @Option(name: [.long], help: "Apple Team ID, used for notarisation.")
    var appleTeamId: String?

    @Option(name: [.long], help: "Apple package signing ID.")
    var packageSigningId: String?

    @Option(name: [.long], help: "Sparkle package signing key.")
    var sparklePackageSignKey: String?

    mutating func run() throws {
        try installIfMissing("create-dmg", "brew install create-dmg")
        try createDmgForAppBundle(
            appBundlePath: appBundlePath,
            productPath: productPath,
            buildPath: buildPath,
            appName: appName,
            packageSigningId: packageSigningId,
            appleId: appleId,
            applePassword: applePassword,
            appleTeamId: appleTeamId,
            sparklePackageSignKey: sparklePackageSignKey
        )
    }
}

struct Package: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Packaging script for the client.")

    @Option(name: [.short, .long], help: "Architecture.")
    var arch = "arm64"

    @Option(name: [.short, .long], help: "Path for build files to be written.")
    var buildPath = "\(FileManager.default.currentDirectoryPath)/build"

    @Option(name: [.short, .long], help: "Path for the final product to be put.")
    var productPath = "\(FileManager.default.currentDirectoryPath)/product"

    @Option(name: [.long], help: "Nextcloud Desktop Client craft blueprint name.")
    var craftBlueprintName = "nextcloud-client"

    @Option(name: [.long], help: "The application's branded name.")
    var appName = "Nextcloud"

    @Option(name: [.long], help: "Apple ID, used for notarisation.")
    var appleId: String?

    @Option(name: [.long], help: "Apple ID password, used for notarisation.")
    var applePassword: String?

    @Option(name: [.long], help: "Apple Team ID, used for notarisation.")
    var appleTeamId: String?

    @Option(name: [.long], help: "Apple package signing ID.")
    var packageSigningId: String?

    @Option(name: [.long], help: "Sparkle package signing key.")
    var sparklePackageSignKey: String?

    mutating func run() throws {
        try packageAppBundle(
            productPath: productPath,
            buildPath: buildPath,
            craftTarget: archToCraftTarget(arch),
            craftBlueprintName: craftBlueprintName,
            appName: appName,
            packageSigningId: packageSigningId,
            appleId: appleId,
            applePassword: applePassword,
            appleTeamId: appleTeamId,
            sparklePackageSignKey: sparklePackageSignKey
        )
    }
}

struct MacCrafter: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A tool to easily build a fully-functional Nextcloud Desktop Client for macOS.",
        subcommands: [Build.self, Codesign.self, Package.self, CreateDMG.self],
        defaultSubcommand: Build.self
    )
}

MacCrafter.main()
