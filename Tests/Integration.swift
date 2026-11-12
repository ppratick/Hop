// Compiled together with the application by test.sh; uses isolated temporary projects.
@MainActor func integrationTest() async {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOP_TEST_ROOT"] ?? fm.temporaryDirectory.appendingPathComponent("Hop-tests-" + UUID().uuidString).path)
    defer { try? fm.removeItem(at: root) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: " + message)
    }
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let reportDate = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!
        let month = openAIMonthStart(reportDate)
        var reporting = OpenAIUsageState()
        reporting.links = ["app": ["key_tally", "key_rotated"]]
        reporting.updatedAt = reportDate
        reporting.costs = [OpenAICostDay(day: month - 86400, keyID: "key_rotated", amount: Decimal(string: "1.25")!),
                           OpenAICostDay(day: month, keyID: "key_tally", amount: Decimal(string: "0.15")!),
                           OpenAICostDay(day: month, keyID: "other", amount: 99)]
        let spending = openAISpending(reporting, projectID: "app", now: reportDate)!
        check(spending.month == Decimal(string: "0.15") && spending.total == Decimal(string: "1.40"),
              "Month and total include linked current and rotated keys without other apps")
        check(openAISpending(reporting, projectID: "unlinked", now: reportDate) == nil,
              "Unlinked projects never show invented zero spending")
        reporting.updatedAt = Date(timeIntervalSince1970: Double(month - 1))
        check(openAISpending(reporting, projectID: "app", now: reportDate)?.month == nil,
              "A previous-month cache cannot report zero for an unsynced new month")
        check(mergeOpenAICosts(reporting.costs, [], since: month).count == 1,
              "Revised zero-cost days replace old values while older history is preserved")
        check(openAIMoney(Decimal(string: "0.0012")!) == "$0.0012" && openAIMoney(Decimal(string: "0.00001")!) == "<$0.0001",
              "Small nonzero costs do not round silently to zero")
        let fixture = OpenAIReportingFixture(month: month)
        let reportingClient = OpenAIClient(key: "fixture-key", transport: { request in try await fixture.send(request) })
        let catalog = try await reportingClient.catalog()
        check(catalog.count == 3 && catalog.contains { $0.id == "key_tally" && $0.name == "Tally" },
              "Read and paginate OpenAI project and key catalogs")
        var expiringKey = catalog[0]
        expiringKey.expiresAt = Int(reportDate.timeIntervalSince1970)
        check(!expiringKey.selectable(at: reportDate), "Hide an API key at its exact expiration")
        expiringKey.expiresAt! += 1
        check(expiringKey.selectable(at: reportDate), "Keep unexpired keys available for selection")
        expiringKey.historical = true
        check(!expiringKey.selectable(at: reportDate), "Hide revoked and historical keys from the picker")
        let report = try await reportingClient.report(since: month - 86400, now: reportDate)
        check(report.costs.reduce(Decimal.zero) { $0 + $1.amount } == Decimal(string: "1.40"),
              "Paginate cost buckets and preserve decimal charges and credits")
        check(report.unattributed && !report.costs.contains { $0.keyID.isEmpty },
              "Exclude unattributed organization charges from individual app totals")
        check(report.historicalKeys.contains { $0.id == "key_rotated" },
              "Make rotated or revoked keys from reporting available for linking")
        check(report.usage.reduce(0) { $0 + $1.requests } == 3 && report.usage.reduce(0) { $0 + $1.input } == 150,
              "Paginate monthly model usage without losing requests or tokens")
        let validReportingRequests = await fixture.validRequests()
        check(validReportingRequests, "Reporting uses only authenticated GETs to OpenAI with grouped queries")
        let denied = OpenAIClient(key: "fixture-secret", transport: { _ in (Data("fixture-secret private error".utf8), 403) })
        do {
            let _: [OpenAIClient.RemoteProject] = try await denied.list("projects")
            check(false, "Reject denied reporting access")
        } catch {
            check(error.localizedDescription.contains("permissions") && !error.localizedDescription.contains("fixture-secret"),
                  "Permission failures explain the issue without exposing credential or response contents")
        }
        let incomplete = OpenAIClient(key: "fixture", transport: { _ in
            (Data(#"{"data":[],"has_more":true,"next_page":"repeated"}"#.utf8), 200)
        })
        do {
            let _: [OpenAIClient.Bucket<OpenAIClient.Cost>] = try await incomplete.buckets("costs", since: month, until: month + 86400, groups: ["api_key_id"], limit: 180)
            check(false, "Reject incomplete reporting pagination")
        } catch { check(error.localizedDescription.contains("incomplete"), "Repeated page cursors cannot publish a partial total") }
        let reportFolder = root.appendingPathComponent("reporting")
        try fm.createDirectory(at: reportFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(reporting).write(to: reportFolder.appendingPathComponent("openai-usage.json"))
        let reportingStore = OpenAIUsageStore(support: reportFolder)
        check(reportingStore.state.links["app"] == ["key_tally", "key_rotated"] && reportingStore.state.costs.count == 3,
              "Persist key links and cached history outside project folders without any credential")
        let encodedReporting = try JSONEncoder().encode(reporting)
        check(!String(decoding: encodedReporting, as: UTF8.self).contains("fixture-key"),
              "Reporting cache does not serialize the Admin API key")
        let remote = root.appendingPathComponent("remote.git").path
        let author = root.appendingPathComponent("author").path
        let reader = root.appendingPathComponent("reader").path
        check(syncGit(root.path, ["init", "--bare", remote]).0 == 0, "Create isolated Git remote")
        check(syncGit(root.path, ["clone", remote, author]).0 == 0, "Clone author repository")
        _ = syncGit(author, ["config", "user.email", "test@example.invalid"])
        _ = syncGit(author, ["config", "user.name", "Hop Test"])
        _ = syncGit(author, ["commit", "--allow-empty", "-m", "Initial"])
        check(syncGit(author, ["push", "-u", "origin", "HEAD"]).0 == 0, "Publish initial test commit")
        check(syncGit(root.path, ["clone", remote, reader]).0 == 0, "Clone reader repository")
        _ = syncGit(author, ["commit", "--allow-empty", "-m", "Mentee update"])
        _ = syncGit(author, ["push"])
        check(checkGitSync(reader, fetch: false).incoming == 0, "Local Git comparison does not fetch remote commits")
        let incoming = checkGitSync(reader)
        check(incoming.ready && incoming.incoming == 1 && incoming.outgoing == 0, "Fetch detects incoming mentee commit")
        check(syncGit(reader, ["pull", "--ff-only", "--no-rebase"]).0 == 0, "Fast-forward pull succeeds")
        check(checkGitSync(reader).incoming == 0, "Pull clears incoming count")
        _ = syncGit(reader, ["config", "user.email", "test@example.invalid"])
        _ = syncGit(reader, ["config", "user.name", "Hop Test"])
        _ = syncGit(reader, ["commit", "--allow-empty", "-m", "Local update"])
        check(checkGitSync(reader).outgoing == 1, "Detect unpushed local commit")
        _ = syncGit(author, ["commit", "--allow-empty", "-m", "Another remote update"])
        _ = syncGit(author, ["push"])
        let diverged = checkGitSync(reader)
        check(diverged.incoming == 1 && diverged.outgoing == 1, "Report both counts for diverged branches")
        check(syncGit(reader, ["pull", "--ff-only", "--no-rebase"]).0 != 0, "Refuse to merge diverged branches")
        check(pushGit(reader).0 != 0, "Block push when remote commits are incoming")
        try Data("one".utf8).write(to: URL(fileURLWithPath: reader).appendingPathComponent("selected file.txt"))
        try Data("two".utf8).write(to: URL(fileURLWithPath: reader).appendingPathComponent("unselected.txt"))
        _ = syncGit(reader, ["add", "unselected.txt"])
        check(changedGitFiles(reader).count == 2, "List staged and untracked files for selection")
        check(commitGitFiles(reader, files: ["selected file.txt"], message: "Selected change").0 == 0, "Commit selected file with spaces")
        check(syncGit(reader, ["diff", "--cached", "--name-only"]).1 == "unselected.txt", "Preserve unrelated staged file")
        check(syncGit(reader, ["show", "--pretty=", "--name-only", "HEAD"]).1 == "selected file.txt", "Exclude unrelated staged file from commit")
        check(commitGitFiles(reader, files: [], message: "Empty").0 != 0, "Reject empty commit selection")
        check(commitGitFiles(reader, files: ["unselected.txt"], message: " ").0 != 0, "Reject blank commit message")
        check(pushGit(author).0 == 0, "Allow push when remote has no incoming changes")
        let platformFolder = root.appendingPathComponent("Platforms")
        try fm.createDirectory(at: platformFolder, withIntermediateDirectories: true)
        let platformXcode = platformFolder.appendingPathComponent("App.xcodeproj")
        try fm.createDirectory(at: platformXcode, withIntermediateDirectories: true)
        try Data("SDKROOT = iphoneos; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";".utf8).write(to: platformXcode.appendingPathComponent("project.pbxproj"))
        check(detectProjectPlatforms(at: platformFolder, xcode: platformXcode.path) == ["iOS"], "Detect iOS from Xcode SDK without duplicate simulator badges")
        try Data("SUPPORTED_PLATFORMS = \"macosx appletvos appletvsimulator\";".utf8).write(to: platformXcode.appendingPathComponent("project.pbxproj"))
        check(detectProjectPlatforms(at: platformFolder, xcode: platformXcode.path) == ["macOS", "tvOS"], "Detect multiple Xcode platforms")
        let webFolder = root.appendingPathComponent("WebPlatform")
        try fm.createDirectory(at: webFolder, withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"next":"latest"}}"#.utf8).write(to: webFolder.appendingPathComponent("package.json"))
        check(detectProjectPlatforms(at: webFolder, xcode: nil) == ["Web"], "Identify web framework projects")
        try Data("import PackageDescription; platforms: [.macOS(.v14)]".utf8).write(to: platformFolder.appendingPathComponent("Package.swift"))
        try Data("SDKROOT = iphoneos;".utf8).write(to: platformXcode.appendingPathComponent("project.pbxproj"))
        check(detectProjectPlatforms(at: platformFolder, xcode: platformXcode.path) == ["iOS"], "Do not label iOS app as macOS because of a supporting test package")
        try Data("print('CLI')".utf8).write(to: webFolder.appendingPathComponent("cli.py"))
        check(detectProjectPlatforms(at: webFolder, xcode: nil) == ["Web", "CLI"], "Detect Web and CLI entry points together")
        let htmlFolder = root.appendingPathComponent("PlainHTML")
        try fm.createDirectory(at: htmlFolder, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: htmlFolder.appendingPathComponent("home.html"))
        try Data("flask".utf8).write(to: htmlFolder.appendingPathComponent("requirements.txt"))
        check(detectProjectPlatforms(at: htmlFolder, xcode: nil) == ["Web"], "Detect HTML websites without index.html")
        let workerFolder = root.appendingPathComponent("Worker")
        try fm.createDirectory(at: workerFolder, withIntermediateDirectories: true)
        try Data(#"{"devDependencies":{"wrangler":"latest"}}"#.utf8).write(to: workerFolder.appendingPathComponent("package.json"))
        check(detectProjectPlatforms(at: workerFolder, xcode: nil) == ["Web"], "Detect Cloudflare web projects")
        let cacheNow = Date()
        check(shouldFetchRemote(lastAttempt: nil, now: cacheNow), "Fetch remote when no cached check exists")
        check(!shouldFetchRemote(lastAttempt: cacheNow.addingTimeInterval(-299), now: cacheNow), "Reuse remote results for five minutes")
        check(shouldFetchRemote(lastAttempt: cacheNow.addingTimeInterval(-300), now: cacheNow), "Fetch again after five minutes")
        check(shouldFetchRemote(lastAttempt: cacheNow, now: cacheNow, force: true), "Manual Git check bypasses remote cache")
        let diffRoot = root.appendingPathComponent("DiffPreview")
        try fm.createDirectory(at: diffRoot, withIntermediateDirectories: true)
        _ = syncGit(diffRoot.path, ["init", "-b", "main"])
        _ = syncGit(diffRoot.path, ["config", "user.email", "test@example.invalid"])
        _ = syncGit(diffRoot.path, ["config", "user.name", "Hop Test"])
        let trackedFile = diffRoot.appendingPathComponent("tracked.txt")
        try Data("base\n".utf8).write(to: trackedFile)
        _ = syncGit(diffRoot.path, ["add", "."])
        _ = syncGit(diffRoot.path, ["commit", "-m", "Baseline"])
        try Data("staged\n".utf8).write(to: trackedFile)
        _ = syncGit(diffRoot.path, ["add", "tracked.txt"])
        try Data("worktree\n".utf8).write(to: trackedFile)
        let beforePreview = syncGit(diffRoot.path, ["status", "--porcelain"]).1
        let trackedDiff = gitFileDiff(diffRoot.path, file: "tracked.txt")
        check(trackedDiff.contains("-base") && trackedDiff.contains("+worktree") && !trackedDiff.contains("+staged"),
              "Preview full file changes from HEAD including staged and unstaged edits")
        check(syncGit(diffRoot.path, ["status", "--porcelain"]).1 == beforePreview, "Preview never changes Git staging")
        try Data("new text\n".utf8).write(to: diffRoot.appendingPathComponent("new 'file.txt"))
        check(gitFileDiff(diffRoot.path, file: "new 'file.txt").contains("+new text"), "Preview untracked filenames containing spaces and quotes")
        try Data([0, 1, 2, 0]).write(to: diffRoot.appendingPathComponent("binary.dat"))
        check(gitFileDiff(diffRoot.path, file: "binary.dat").contains("Binary files"), "Explain binary changes without rendering binary data")
        try fm.removeItem(at: trackedFile)
        check(gitFileDiff(diffRoot.path, file: "tracked.txt").contains("-base"), "Preview deleted tracked files")
        check(gitFileDiff(diffRoot.path, file: "../outside").contains("outside the project"), "Keep diff previews inside the project")
        let oldDisk = try JSONDecoder().decode(DiskState.self, from: Data("{}".utf8))
        check(oldDisk.devices.isEmpty && oldDisk.signingRecords.isEmpty && oldDisk.deployments.isEmpty, "Older settings load with empty device tracking")
        var oldDeployment = try JSONDecoder().decode(DeploymentConfig.self, from: Data(#"{"deviceID":"phone-id","scheme":"App","buildID":"build","artifactPath":""}"#.utf8))
        check(oldDeployment.developmentTeam == nil && deploymentSigningArguments(oldDeployment).isEmpty,
              "Existing deployments preserve project signing settings")
        oldDeployment.developmentTeam = " TEAM123456 "
        check(deploymentSigningArguments(oldDeployment) == ["DEVELOPMENT_TEAM=TEAM123456"],
              "Local team override applies to the app and extensions in the build command")
        let deviceJSON = Data(#"{"result":{"devices":[{"identifier":"phone","properties":{"hardware":{"udid":"phone-id","reality":"physical","platform":"iOS","marketingName":"iPhone"},"state":{"name":"Test Phone"},"connection":{"state":"connected","pairingState":"paired"}}},{"identifier":"sim","properties":{"hardware":{"reality":"simulated"}}}]}}"#.utf8)
        let parsedDevices = try parseHopDevices(deviceJSON)
        check(parsedDevices.count == 1 && parsedDevices[0].id == "phone-id", "Discover physical devices and exclude simulators")
        let unpairedJSON = Data(#"{"result":{"devices":[{"identifier":"unpaired","properties":{"hardware":{"reality":"physical"},"connection":{"pairingState":"unpaired"}}}]}}"#.utf8)
        let unpairedDevices = try parseHopDevices(unpairedJSON)
        check(unpairedDevices.isEmpty, "Exclude unpaired devices from the device list")
        var statusDevice = parsedDevices[0]
        statusDevice.state = "disconnected"
        check(statusDevice.statusLabel == "Available", "Idle developer connection displays as available")
        statusDevice.state = "unavailable"
        check(statusDevice.statusLabel == "Unavailable", "Unreachable device displays as unavailable")
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        let profileData = try PropertyListSerialization.data(fromPropertyList: [
            "ExpirationDate": expiration, "ProvisionedDevices": ["phone-id"],
            "Entitlements": ["application-identifier": "TEAM.com.example.app"]
        ], format: .xml, options: 0)
        let parsedProfile = try parseSigningProfile(profileData)
        check(parsedProfile.expires == expiration && parsedProfile.bundleID == "com.example.app" && parsedProfile.devices == ["phone-id"], "Read actual provisioning expiration and eligible devices")
        do {
            _ = try parseSigningProfile(Data("invalid".utf8))
            check(false, "Reject invalid provisioning data")
        } catch { check(true, "Reject invalid provisioning data") }
        let signing = SigningRecord(projectID: "project", deviceID: "phone-id", bundleID: "com.example.app",
                                    installedAt: expiration.addingTimeInterval(-604800), expiresAt: expiration, profileBased: true, artifactPath: "")
        check(signing.remaining(at: expiration.addingTimeInterval(-432000)) == "5 days remaining", "Display five-day signing countdown")
        check(signing.remaining(at: expiration) == "Expired", "Mark expired signing at the exact expiration")
        try validateDeploymentProfile(parsedProfile, bundleID: "com.example.app", deviceID: "phone-id")
        check(parsedProfile.expires == expiration, "Accept a reused valid profile without extending its recorded expiration")
        do {
            let expired = SigningProfile(expires: .distantPast, bundleID: "com.example.app", devices: ["phone-id"])
            try validateDeploymentProfile(expired, bundleID: "com.example.app", deviceID: "phone-id")
            check(false, "Reject expired profiles before installation")
        } catch { check(true, "Reject expired profiles before installation") }
        do {
            try validateDeploymentProfile(parsedProfile, bundleID: "com.wrong.app", deviceID: "phone-id")
            check(false, "Reject app/profile identifier mismatch")
        } catch { check(true, "Reject app/profile identifier mismatch") }
        do {
            try validateDeploymentProfile(parsedProfile, bundleID: "com.example.app", deviceID: "other-device")
            check(false, "Reject profile not signed for the selected device")
        } catch { check(true, "Reject profile not signed for the selected device") }
        let derivedFixture = root.appendingPathComponent("DeviceBuildFixture")
        let deviceApp = derivedFixture.appendingPathComponent("Build/Products/Debug-iphoneos/Fixture.app")
        let simulatorApp = derivedFixture.appendingPathComponent("Build/Products/Debug-iphonesimulator/Fixture.app")
        for app in [deviceApp, simulatorApp] {
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app"], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
            try Data("placeholder".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        }
        let selectedDeviceApp = try builtDeviceApp(in: derivedFixture, preferredBundle: "com.example.app", scheme: "Fixture")
        check(selectedDeviceApp.resolvingSymlinksInPath().path == deviceApp.resolvingSymlinksInPath().path, "Select device build and exclude simulator products")
        let macConfig = DeploymentConfig(deviceID: localMacDeviceID, scheme: "MacFixture")
        check(macConfig.isMac && deploymentDestination(macConfig) == "platform=macOS" &&
              deploymentDestination(oldDeployment) == "id=phone-id", "Use the local Mac destination without changing device builds")
        let macProducts = root.appendingPathComponent("Mac products with spaces")
        let macApp = macProducts.appendingPathComponent("Custom Product.app")
        try fm.createDirectory(at: macApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let macInfo: [String: Any] = ["CFBundleIdentifier": "com.example.macfixture", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: macInfo, format: .xml, options: 0).write(to: macApp.appendingPathComponent("Contents/Info.plist"))
        let macExecutable = macApp.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: macExecutable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macExecutable.path)
        let macSettings: [[String: Any]] = [["target": "MacFixture", "buildSettings": [
            "PLATFORM_NAME": "macosx", "WRAPPER_EXTENSION": "app", "PRODUCT_TYPE": "com.apple.product-type.application",
            "TARGET_BUILD_DIR": macProducts.path, "FULL_PRODUCT_NAME": "Custom Product.app"]]]
        let macProduct = try macBuildProduct(JSONSerialization.data(withJSONObject: macSettings), scheme: "MacFixture")
        check(macProduct.path == macApp.path, "Resolve the selected scheme’s Mac app with custom names and paths")
        do {
            _ = try macBuildProduct(Data("[]".utf8), scheme: "Library")
            check(false, "Reject schemes without a macOS app")
        } catch { check(true, "Reject schemes without a macOS app") }
        let applications = root.appendingPathComponent("Test Applications")
        let installedMac = try installMacApp(macApp, in: applications)
        let installedBundleID = try macAppBundleID(installedMac)
        check(installedBundleID == "com.example.macfixture", "Install a Mac app with its bundle contents intact")
        try Data("old".utf8).write(to: installedMac.appendingPathComponent("obsolete.txt"))
        try Data("new".utf8).write(to: macApp.appendingPathComponent("new.txt"))
        _ = try installMacApp(macApp, in: applications)
        check(!fm.fileExists(atPath: installedMac.appendingPathComponent("obsolete.txt").path) &&
              fm.fileExists(atPath: installedMac.appendingPathComponent("new.txt").path), "Replace the full Mac app atomically without leaving obsolete files")
        let otherApp = applications.appendingPathComponent("Other.app")
        try fm.createDirectory(at: otherApp, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: otherApp.appendingPathComponent("original.txt"))
        do {
            _ = try installMacApp(macApp, in: applications, name: "Other.app")
            check(false, "Protect an unrelated app from replacement")
        } catch {
            check(fm.fileExists(atPath: otherApp.appendingPathComponent("original.txt").path), "Protect an unrelated app from replacement")
        }
        let linkedApp = applications.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: linkedApp, withDestinationURL: installedMac)
        do {
            _ = try installMacApp(macApp, in: applications, name: "Link.app")
            check(false, "Reject symbolic-link installation destinations")
        } catch { check(true, "Reject symbolic-link installation destinations") }
        let applicationFiles = try fm.contentsOfDirectory(atPath: applications.path)
        check(applicationFiles.allSatisfy { !$0.hasPrefix(".hop-install-") }, "Remove staged app copies after installation")
        let macRecord = SigningRecord(projectID: "mac", deviceID: localMacDeviceID, bundleID: "com.example.macfixture",
                                      installedAt: Date(), expiresAt: .distantFuture, profileBased: false, artifactPath: installedMac.path)
        check(macRecord.remaining() == "Installed", "Show Mac installation status without inventing a provisioning countdown")
        let commandLog = root.appendingPathComponent("command-test.log")
        _ = try deploymentCommand(Process(), arguments: ["--version"], log: commandLog, timeout: 10)
        check(fm.fileExists(atPath: commandLog.path), "Capture deployment command logs outside project files")
        let jsonOutput = try deploymentCommand(Process(), arguments: ["sh", "-c", "printf 'Xcode destination warning\\n' >&2; printf '[]\\n'"],
                                               log: commandLog, timeout: 10, standardOutputOnly: true)
        let decodedOutput = try JSONSerialization.jsonObject(with: jsonOutput) as? [Any]
        let diagnosticLog = try String(contentsOf: commandLog, encoding: .utf8)
        check(decodedOutput?.isEmpty == true && diagnosticLog.contains("Xcode destination warning") && diagnosticLog.contains("[]"),
              "Keep Xcode warnings out of JSON while preserving diagnostics in the log")
        let logFiles = try fm.contentsOfDirectory(atPath: root.path)
        check(logFiles.allSatisfy { !$0.hasPrefix(".stderr-") }, "Clean up temporary command diagnostic files")
        do {
            _ = try macBuildProduct(Data("not JSON".utf8), scheme: "MacFixture")
            check(false, "Explain malformed Mac build settings")
        } catch {
            check(error.localizedDescription.contains("build settings"), "Explain malformed Mac build settings")
        }
        do {
            _ = try deploymentCommand(Process(), arguments: ["--find", "hop-nonexistent-test-tool"], log: commandLog, timeout: 10)
            check(false, "Propagate failed deployment commands")
        } catch { check(true, "Propagate failed deployment commands") }
        var deviceDisk = DiskState()
        deviceDisk.devices = parsedDevices; deviceDisk.signingRecords = [signing]
        deviceDisk.deployments["project"] = DeploymentConfig(deviceID: "phone-id", scheme: "Fixture")
        let loadedDeviceDisk = try JSONDecoder().decode(DiskState.self, from: JSONEncoder().encode(deviceDisk))
        check(loadedDeviceDisk.devices == parsedDevices && loadedDeviceDisk.signingRecords.first?.expiresAt == expiration && loadedDeviceDisk.deployments["project"]?.scheme == "Fixture",
              "Persist device mapping and exact signing expiration")
        let projects = root.appendingPathComponent("Development")
        let web = projects.appendingPathComponent("CC/Student's Web App")
        let old = projects.appendingPathComponent("Older App")
        let junk = web.appendingPathComponent("node_modules/fake")
        let backend = web.appendingPathComponent("backend")
        for u in [web, old, junk, backend] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: web.appendingPathComponent("package.json"))
        try Data(#"{"scripts":{"start":"node server.js"}}"#.utf8).write(to: backend.appendingPathComponent("package.json"))
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: junk.appendingPathComponent("package.json"))
        try Data("# Python".utf8).write(to: old.appendingPathComponent("requirements.txt"))
        let oldDate = Date(timeIntervalSinceNow: -86400)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: old.appendingPathComponent("requirements.txt").path)
        _ = capture("/usr/bin/git", ["init", "-b", "main", web.path])
        _ = capture("/usr/bin/git", ["-C", web.path, "remote", "add", "origin", "git@github.com:example/project.git"])
        let found = scan(projects.path)
        check(found.count == 2, "Discover nested projects, skip dependencies, group backend services")
        check(found.first?.title == web.lastPathComponent, "Sort meaningful modification dates")
        let project = found.first!
        let xcodeFixture = root.appendingPathComponent("Fixture.xcodeproj")
        try fm.createDirectory(at: xcodeFixture, withIntermediateDirectories: true)
        let xcodeObjects: [String: Any] = [
            "app": ["productType": "com.apple.product-type.application", "buildConfigurationList": "appConfigs"],
            "tests": ["productType": "com.apple.product-type.bundle.ui-testing", "buildConfigurationList": "testConfigs"],
            "appConfigs": ["buildConfigurations": ["appDebug"]],
            "testConfigs": ["buildConfigurations": ["testDebug"]],
            "appDebug": ["buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.fixture"]],
            "testDebug": ["buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.fixture.UITests"]]
        ]
        let xcodeData = try PropertyListSerialization.data(fromPropertyList: ["objects": xcodeObjects], format: .xml, options: 0)
        try xcodeData.write(to: xcodeFixture.appendingPathComponent("project.pbxproj"))
        var xcodeProject = project
        xcodeProject.xcode = xcodeFixture.path
        check(xcodeAppBundleID(xcodeProject) == "com.example.fixture", "Autofill bundle ID from the app target, excluding UI tests")
        xcodeProject.xcode = nil
        check(xcodeAppBundleID(xcodeProject) == nil, "Do not autofill Xcode metadata for ordinary projects")
        check(project.github == "https://github.com/example/project", "Resolve SSH GitHub remote")
        check(project.branch == "main" && project.changes > 0, "Read Git branch and working changes")
        check(project.suggested.count == 2, "Find root and backend launch commands")
        check(shellQuote(web.path).contains("'\\''"), "Quote project paths containing apostrophes")
        let gestureStore = Store(storage: root.appendingPathComponent("GestureSettings"), root: projects.path, autoRefresh: false)
        gestureStore.projects = found
        let sourceID = project.id, targetID = found.last!.id
        let dragFolderA = gestureStore.createFolder("Drag A")!, dragFolderB = gestureStore.createFolder("Drag B")!
        gestureStore.dragFrames["settings"] = [
            OrganizerItem.project(sourceID).key: OrganizerFrame(item: .project(sourceID), rect: CGRect(x: 0, y: 0, width: 200, height: 50)),
            OrganizerItem.project(targetID).key: OrganizerFrame(item: .project(targetID), rect: CGRect(x: 0, y: 60, width: 200, height: 50)),
            "folderA": OrganizerFrame(item: .folder(dragFolderA), rect: CGRect(x: 0, y: 120, width: 200, height: 50)),
            "folderB": OrganizerFrame(item: .folder(dragFolderB), rect: CGRect(x: 0, y: 180, width: 200, height: 50))]
        gestureStore.dragFrames["menu"] = ["other": OrganizerFrame(item: .folder(dragFolderB), rect: CGRect(x: 0, y: 60, width: 200, height: 50))]
        gestureStore.updateOrganizerDrag(.project(sourceID), scope: "settings", point: CGPoint(x: 20, y: 95))
        check(gestureStore.dragHover == .project(targetID, after: true), "Route a real drag location to the lower project insertion edge")
        check(gestureStore.projectDragOffset(found.last!, scope: "settings").height < 0, "Hover preview shifts the target card into the source slot")
        check(gestureStore.projectDragOffset(found.last!, scope: "menu") == .zero, "Drag previews stay within their own list")
        check(gestureStore.disk.order != .manual, "Hover preview does not persist a reorder before drop")
        gestureStore.finishOrganizerDrag()
        check(gestureStore.orderedProjects(includeHidden: true).last?.id == sourceID, "Commit the gesture's project reorder")
        check(gestureStore.dragScope == nil && gestureStore.dragHover == nil && gestureStore.draggingProject == nil, "Clear drag state after dropping")
        gestureStore.updateOrganizerDrag(.project(sourceID), scope: "settings", point: CGPoint(x: 20, y: 70))
        check(gestureStore.dragHover == .project(targetID, after: false), "Keep menu and Settings drag coordinate spaces isolated")
        gestureStore.finishOrganizerDrag()
        gestureStore.updateOrganizerDrag(.project(sourceID), scope: "settings", point: CGPoint(x: 20, y: 140))
        check(gestureStore.dragHover == .insideFolder(dragFolderA), "Recognize dropping a project onto a folder")
        gestureStore.finishOrganizerDrag()
        check(gestureStore.folderID(project) == dragFolderA, "Move projects into folders using the gesture destination")
        gestureStore.updateOrganizerDrag(.folder(dragFolderB), scope: "settings", point: CGPoint(x: 20, y: 130))
        check(gestureStore.dragHover == .folder(dragFolderA, after: false), "Recognize folder insertion from the pointer location")
        gestureStore.finishOrganizerDrag()
        check(gestureStore.orderedGroupIDs.first == dragFolderB, "Commit the gesture's folder reorder")
        check(gestureStore.projectDragOffset(found.last!, scope: "settings") == .zero, "Drop clears live card offsets")
        let beforeInvalidDrop = gestureStore.disk.groupOrder
        gestureStore.updateOrganizerDrag(.folder(dragFolderB), scope: "settings", point: CGPoint(x: 500, y: 500))
        gestureStore.finishOrganizerDrag()
        check(gestureStore.disk.groupOrder == beforeInvalidDrop, "Dropping outside a destination leaves order unchanged")
        let staticRoot = root.appendingPathComponent("Static discovery")
        let staticSite = staticRoot.appendingPathComponent("CC/carProject")
        let staticImages = staticSite.appendingPathComponent("images")
        try fm.createDirectory(at: staticImages, withIntermediateDirectories: true)
        try Data("<html>Static website</html>".utf8).write(to: staticSite.appendingPathComponent("index.html"))
        try Data("body {}".utf8).write(to: staticSite.appendingPathComponent("style.css"))
        try Data("<html>Nested asset page</html>".utf8).write(to: staticImages.appendingPathComponent("index.html"))
        let staticFound = scan(staticRoot.path)
        check(staticFound.count == 1 && staticFound.first?.title == "carProject", "Discover plain HTML websites without Git or package manifests")
        let organizationStorage = root.appendingPathComponent("OrganizationSettings")
        let organizer = Store(storage: organizationStorage, root: projects.path, autoRefresh: false); organizer.projects = found
        let classes = organizer.createFolder("Classes")!, mentoring = organizer.createFolder("Mentoring")!
        check(classes != mentoring && organizer.disk.folders.count == 2, "Create distinct organization folders")
        _ = organizer.assignFolder(project.id, to: classes); _ = organizer.assignFolder(found.last!.id, to: classes)
        check(organizer.folderID(project) == classes && !organizer.isInMenu(project), "Organizing a project never bypasses menu approval")
        _ = organizer.placeProject(project.id, relativeTo: found.last!.id, after: true)
        check(organizer.orderedProjects(includeHidden: true).last?.id == project.id, "Insert dragged projects after the indicated row")
        _ = organizer.placeProject(project.id, relativeTo: found.last!.id, after: false)
        check(organizer.orderedProjects(includeHidden: true).first?.id == project.id, "Insert dragged projects before the indicated row")
        _ = organizer.dropIntoFolder(project.id, folder: mentoring)
        organizer.renameFolder(mentoring, to: "Mentoring Projects"); organizer.toggleFolder(mentoring)
        let organizationRestored = Store(storage: organizationStorage, autoRefresh: false); organizationRestored.projects = found
        check(organizationRestored.folderID(project) == mentoring && organizationRestored.disk.collapsedFolders.contains(mentoring), "Persist folder membership and collapsed state")
        check(organizationRestored.disk.folders.last?.title == "Mentoring Projects", "Rename virtual folders")
        check(organizer.moveFolder(mentoring, relativeTo: classes, after: false), "Move a folder before another folder")
        check(organizer.orderedGroupIDs.first == mentoring, "Apply custom folder ordering")
        _ = organizer.moveFolder(Store.ungroupedFolderID, relativeTo: mentoring, after: false)
        check(organizer.orderedGroupIDs.first == Store.ungroupedFolderID, "Reorder Ungrouped alongside named folders")
        let folderOrderRestored = Store(storage: organizationStorage, autoRefresh: false)
        check(folderOrderRestored.orderedGroupIDs == organizer.orderedGroupIDs, "Persist folder order across launches")
        check(organizer.folderID(project) == mentoring && fm.fileExists(atPath: web.path), "Moving folders preserves project membership and files")
        check(!organizer.moveFolder(mentoring, relativeTo: mentoring, after: true) && !organizer.moveFolder("missing", relativeTo: mentoring, after: false), "Reject invalid folder reorder operations")
        organizer.removeFolder(classes)
        check(organizer.folderID(found.last!) == nil && fm.fileExists(atPath: old.path), "Removing a folder ungroups projects without deleting their files")
        check(!organizer.assignFolder(project.id, to: "missing-folder"), "Reject unknown folder destinations")
        let outside = root.appendingPathComponent("Elsewhere/Plain Folder")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("A project without a recognized manifest".utf8).write(to: outside.appendingPathComponent("source.txt"))
        check(organizer.addManualProject(outside), "Manually add a project outside the discovery folder")
        for _ in 0..<100 { if !organizer.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        let externalPath = outside.resolvingSymlinksInPath().standardizedFileURL.path
        check(organizer.projects.contains(where: { $0.id == externalPath }) && organizer.disk.projects[externalPath]?.admission == .pending, "Load manual projects without manifests and require setup approval")
        let alias = root.appendingPathComponent("Project alias"); try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
        _ = organizer.addManualProject(alias)
        for _ in 0..<100 { if !organizer.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(organizer.disk.manualPaths.count == 1, "Deduplicate manually added projects through symlinks")
        check(scan(projects.path, manualPaths: [web.path]).count == 2, "Deduplicate projects found both automatically and manually")
        let emptySource = root.appendingPathComponent("Empty source"); try fm.createDirectory(at: emptySource, withIntermediateDirectories: true)
        organizer.changeSettings { $0.root = emptySource.path }; organizer.refresh()
        for _ in 0..<100 { if !organizer.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(organizer.projects.map(\.id) == [externalPath], "Keep manual projects when the discovery source changes")
        organizer.removeManualProject(externalPath)
        for _ in 0..<100 { if !organizer.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(organizer.projects.isEmpty && fm.fileExists(atPath: outside.path), "Stop tracking manual projects without touching their files")
        let removalStorage = root.appendingPathComponent("RemovalSettings")
        let removal = Store(storage: removalStorage, root: projects.path, autoRefresh: false); removal.projects = found
        removal.update(project) { $0.admission = .added; $0.note = "Keep my notes" }
        removal.hideProject(project)
        check(!removal.isInMenu(project) && removal.orderedProjects(includeHidden: true).contains(where: { $0.id == project.id }), "Hide projects from the menu while keeping them in Settings")
        removal.update(project) { $0.hidden = false }
        check(removal.removeProject(project) && fm.fileExists(atPath: web.path), "Remove projects from Hop without deleting files")
        removal.refresh()
        for _ in 0..<100 { if !removal.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(!removal.projects.contains(where: { $0.id == project.id }), "Suppress removed projects during automatic rediscovery")
        let removedRestored = Store(storage: removalStorage, autoRefresh: false)
        check(removedRestored.disk.removedProjects.contains(project.id), "Persist removed-project exclusions across launches")
        removal.restoreProject(project.id)
        for _ in 0..<100 { if !removal.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(removal.projects.contains(where: { $0.id == project.id }) && removal.prefs(project).note == "Keep my notes", "Restore removed projects with their configuration intact")
        removal.toggleFolder(Store.ungroupedFolderID)
        let collapsedRestored = Store(storage: removalStorage, autoRefresh: false)
        check(collapsedRestored.disk.collapsedFolders.contains(Store.ungroupedFolderID), "Persist Ungrouped collapse state")
        let admissionStorage = root.appendingPathComponent("AdmissionSettings")
        let discovery = Store(storage: admissionStorage, root: projects.path, autoRefresh: false)
        var prompts: [String] = []
        discovery.reviewRequested = { prompts.append($0.id) }
        discovery.refresh()
        for _ in 0..<100 { if !discovery.scanning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(discovery.projects.count == 2 && discovery.orderedProjects().isEmpty, "Discover new projects in Settings without adding them to the menu")
        check(prompts.count == 1 && discovery.reviewProject != nil, "Prompt for one newly discovered project at a time")
        check(discovery.processes.isEmpty, "Discovery and setup never start local services")
        let firstReview = discovery.reviewProject!
        discovery.finishReview(firstReview, add: false)
        discovery.offerNextReview()
        check(discovery.prefs(firstReview).admission == .settingsOnly && discovery.reviewProject?.id != firstReview.id, "Keep declined projects in Settings and advance the review queue")
        let accepted = discovery.reviewProject!
        var configured = discovery.prefs(accepted); configured.editor = "Xcode"; configured.website = "example.com"
        discovery.finishReview(accepted, preferences: configured)
        check(discovery.orderedProjects().map(\.id) == [accepted.id] && discovery.prefs(accepted).selected.isEmpty, "Only approved projects enter the menu, with actions still unchecked")
        let restoredAdmission = Store(storage: admissionStorage, autoRefresh: false); restoredAdmission.projects = found
        restoredAdmission.reviewRequested = { _ in prompts.append("unexpected") }; restoredAdmission.offerNextReview()
        check(restoredAdmission.reviewProject == nil && restoredAdmission.prefs(accepted).website == "example.com", "Remember admission decisions and configuration without repeat prompts")
        discovery.update(firstReview) { $0.admission = .pending }
        discovery.beginReview(firstReview); discovery.finishReview(firstReview)
        discovery.offerNextReview()
        check(discovery.reviewProject == nil && discovery.pendingProjects.count == 1, "Not now defers a project without immediately prompting again")
        let deferred = Store(storage: admissionStorage, autoRefresh: false); deferred.projects = found; deferred.reviewRequested = { _ in }; deferred.offerNextReview()
        check(deferred.reviewProject?.id == firstReview.id, "Offer deferred projects again on a future launch")
        let storage = root.appendingPathComponent("Settings")
        let store = Store(storage: storage, root: projects.path, autoRefresh: false)
        store.projects = found
        check(Preferences().selected.isEmpty, "New projects start with no launch actions selected")
        let legacy = try JSONSerialization.data(withJSONObject: ["root": projects.path, "projects": [project.id: ["title": "Legacy", "pinned": true, "hidden": false, "editor": "Xcode", "website": "", "note": "Keep this note", "selected": ["editor", "terminal"], "services": [], "customizedServices": false]]])
        let migrated = try JSONDecoder().decode(DiskState.self, from: legacy)
        check(migrated.projects[project.id]?.selected.isEmpty == true && migrated.projects[project.id]?.note == "Keep this note" && migrated.projects[project.id]?.admission == nil, "Migrate old defaults to unchecked while preserving project notes")
        store.update(project) { $0.admission = .added; $0.title = "Friendly name"; $0.pinned = true; $0.hidden = true; $0.note = "Continue here"; $0.selected = ["editor", "terminal"] }
        let restored = Store(storage: storage, autoRefresh: false)
        check(restored.prefs(project).pinned && restored.prefs(project).hidden && restored.prefs(project).note == "Continue here", "Persist favorites, visibility, notes, and selections")
        check(restored.prefs(project).selected == ["editor", "terminal"], "Remember explicitly selected launch actions after reopening")
        store.update(project) { $0.hidden = false; $0.pinned = false; $0.title = "Zeta" }
        store.update(found.last!) { $0.admission = .added; $0.title = "Alpha" }
        store.changeSettings { $0.order = .alphabetical }
        check(store.orderedProjects().first?.id == found.last!.id, "Sort alphabetically by displayed project name")
        store.moveProject(project.id, before: found.last!.id)
        check(store.disk.order == .manual && store.orderedProjects().first?.id == project.id, "Dragging switches to manual order")
        let manualRestored = Store(storage: storage, autoRefresh: false); manualRestored.projects = found
        check(manualRestored.orderedProjects().first?.id == project.id && manualRestored.disk.order == .manual, "Persist manual project order")
        store.update(found.last!) { $0.pinned = true }
        check(store.orderedProjects().first?.id == found.last!.id, "Keep favorites above manually ordered projects")
        store.changeSettings { $0.pinnedFirst = false; $0.refreshSeconds = 0; $0.refreshOnOpen = false }
        check(store.orderedProjects().first?.id == project.id && store.timer == nil, "Honor pin grouping and refresh settings")
        check(fm.fileExists(atPath: web.path), "Renaming display title preserves project folder")
        store.update(project) { $0.website = ""; $0.services = [Service(name: "Incomplete", directory: project.path, command: "", url: "localhost:3000")]; $0.selected = ["website"] }
        check(!store.availableActions(project).contains("website") && !store.availableActions(project).contains(where: { $0.hasPrefix("server:") || $0.hasPrefix("web:") }), "Hide unconfigured websites and incomplete services from menu actions")
        check(store.prefs(project).selected.intersection(store.availableActions(project)).isEmpty, "Ignore saved selections for actions that are no longer configured")
        store.update(project) { $0.website = "example.com"; $0.services = project.suggested }
        check(store.availableActions(project).contains("website") && store.availableActions(project).contains("github"), "Show configured website and detected GitHub actions")
        check(store.validURL("example.com")?.absoluteString == "https://example.com" && store.validURL("localhost:3000", local: true)?.absoluteString == "http://localhost:3000", "Accept website and local addresses without protocol prefixes")
        check(store.validURL("file:///etc/passwd") == nil && store.validURL("https://example.com", local: true) == nil, "Validate website schemes and restrict local probes to loopback")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(result == 0, "Allocate an unused local test port")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: addr.sin_port); close(fd)
        let service = Service(name: "Test server", directory: web.path, command: "/usr/bin/python3 -m http.server \(port) --bind 127.0.0.1", url: "http://127.0.0.1:\(port)")
        await store.start(project, service)
        let key = store.key(project,service)
        if store.phase(project,service) != "Running" {
            print("Server state: \(store.phase(project,service)); \(store.message)")
            if let log = store.logURLs[key] { print((try? String(contentsOf: log, encoding: .utf8)) ?? "No log") }
        }
        check(store.phase(project,service) == "Running", "Start a real HTTP server and wait for readiness")
        store.update(project) { $0.services = [service] }
        check(!store.removeProject(project) && store.projects.contains(where: { $0.id == project.id }), "Keep projects with managed services available until those services stop")
        store.message = ""
        let originalPID = store.processes[key]?.processIdentifier
        await store.start(project,service)
        check(store.processes[key]?.processIdentifier == originalPID, "Reuse owned servers rather than start duplicates")
        let otherStore = Store(storage: root.appendingPathComponent("OtherSettings"), autoRefresh: false)
        await otherStore.start(project,service)
        check(otherStore.external.contains(key) && otherStore.processes[key] == nil, "Detect external servers without taking ownership")
        let conflicting = Service(name: "Other project", directory: old.path, command: "exit 0", url: service.url)
        await otherStore.start(found.last!, conflicting)
        check(otherStore.phase(found.last!,conflicting) == "Address already in use", "Reject an unrelated project using the same port")
        otherStore.stop(project, service)
        let stillAlive = await store.reachable(URL(string: service.url)!)
        check(stillAlive, "Never stop a server owned by another process")
        store.stop(project,service)
        for _ in 0..<40 { if store.processes[key] == nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        let alive = await store.reachable(URL(string: service.url)!)
        check(store.processes[key] == nil && !alive, "Stop the server and release its port")
        check(DiskState().commandMode == .background, "Keep background execution as the default")
        store.changeSettings { $0.commandMode = .terminal }
        let restoredMode = Store(storage: storage, autoRefresh: false)
        check(restoredMode.disk.commandMode == .terminal, "Persist the Background/Terminal execution preference")
        let terminalState = root.appendingPathComponent("terminal-run.json")
        try Data().write(to: terminalState)
        let terminalOutput = root.appendingPathComponent("terminal-output.log")
        fm.createFile(atPath: terminalOutput.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: terminalOutput)
        let runner = Process(); runner.executableURL = Bundle.main.executableURL
        runner.arguments = ["--terminal-service", service.command, terminalState.path]; runner.currentDirectoryURL = web
        runner.standardOutput = outputHandle; runner.standardError = outputHandle
        try runner.run()
        store.terminalRuns[key] = terminalState; store.monitorTerminal(key, terminalState)
        var terminalReady = false
        for _ in 0..<60 {
            if await store.reachable(URL(string: service.url)!) { terminalReady = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check(terminalReady && store.isManaged(key), "Run a real service through the Terminal runner with tracked ownership")
        let identity = TerminalRecord.read(terminalState)!
        var incorrectIdentity = identity; incorrectIdentity.seconds += 1
        check(identity.isAlive && !incorrectIdentity.isAlive, "Verify process identity before stopping Terminal jobs")
        store.stop(project, service)
        for _ in 0..<50 { if !store.isManaged(key) { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        runner.waitUntilExit(); try outputHandle.close()
        let terminalAlive = await store.reachable(URL(string: service.url)!)
        check(!terminalAlive && !store.isManaged(key), "Stop Terminal services and release their ports")
        let displayedOutput = try String(contentsOf: terminalOutput, encoding: .utf8)
        check(displayedOutput.contains("$ " + service.command) && displayedOutput.contains("Service stopped"), "Show commands and service output in the Terminal stream")
        let interruptState = root.appendingPathComponent("terminal-interrupt.json"); try Data().write(to: interruptState)
        let interruptRunner = Process(); interruptRunner.executableURL = Bundle.main.executableURL; interruptRunner.arguments = ["--terminal-service", "sleep 30", interruptState.path]
        interruptRunner.standardOutput = FileHandle.nullDevice; interruptRunner.standardError = FileHandle.nullDevice
        try interruptRunner.run()
        for _ in 0..<40 { if TerminalRecord.read(interruptState)?.isAlive == true { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let record = TerminalRecord.read(interruptState) { Darwin.kill(-record.pid, SIGINT) }
        for _ in 0..<40 { if !interruptRunner.isRunning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        if interruptRunner.isRunning { Darwin.kill(-interruptRunner.processIdentifier, SIGKILL) }
        interruptRunner.waitUntilExit()
        check(TerminalRecord.read(interruptState)?.exitStatus == 130, "Handle Terminal Ctrl-C and return control to the shell")
        let failedState = root.appendingPathComponent("terminal-failure.json"); try Data().write(to: failedState)
        let failureRunner = Process(); failureRunner.executableURL = Bundle.main.executableURL; failureRunner.arguments = ["--terminal-service", "exit 7", failedState.path]
        failureRunner.standardOutput = FileHandle.nullDevice; failureRunner.standardError = FileHandle.nullDevice
        try failureRunner.run(); failureRunner.waitUntilExit()
        check(TerminalRecord.read(failedState)?.exitStatus == 7, "Report terminal command exit status")
        store.changeSettings { $0.commandMode = .background }
        let failing = Service(name: "Failure", directory: web.path, command: "exit 7", url: "")
        await store.start(project,failing)
        for _ in 0..<20 { if store.processes[store.key(project,failing)] == nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        check(store.phase(project,failing) == "Exited (7)", "Surface launch failures")
        if let output = ProcessInfo.processInfo.environment["HOP_PREVIEW"] {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            store.update(project) { $0.hidden = false; $0.title = "Student Web App"; $0.services = project.suggested; $0.note = "Next: finish the session dashboard." }
            let previewFolder = store.createFolder("Mentoring")!
            _ = store.assignFolder(project.id, to: previewFolder)
            _ = store.createFolder("Personal")
            store.expanded = project.id
            let view = NSHostingView(rootView: RootView(store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 680)
            window.displayIfNeeded(); view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            }
        }
        if let output = ProcessInfo.processInfo.environment["HOP_SETTINGS_PREVIEW"] {
            let view = NSHostingView(rootView: SettingsView(store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; view.frame = NSRect(x: 0, y: 0, width: 920, height: 720)
            window.displayIfNeeded(); view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            }
            store.settingsProject = project.id
            window.displayIfNeeded(); view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + ".project.png"))
            }
        }
        let delegate = AppDelegate(); delegate.store = store
        delegate.openSettings(nil)
        check(delegate.settingsWindow?.isVisible == true && store.settingsProject == nil, "Open a separate native settings window")
        let window = delegate.settingsWindow
        store.projectPage = .configure
        delegate.openSettings(project.id)
        check(store.projectPage == .overview, "Opening a project starts on Overview")
        check(delegate.settingsWindow === window && store.settingsProject == project.id, "Reuse settings window and open the selected project")
        store.reviewRequested = { project in delegate.openSettings(project.id) }
        store.beginReview(project)
        for _ in 0..<40 { if delegate.settingsWindow?.attachedSheet != nil { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        check(delegate.settingsWindow?.attachedSheet != nil, "Present new-project review as a native settings sheet")
        store.finishReview(project)
        try? await Task.sleep(nanoseconds: 250_000_000)
        delegate.settingsWindow?.close()
        check(NSApp.activationPolicy() == .accessory, "Return to menu-bar mode after closing settings")
        print("All integration checks passed.")
        exit(0)
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}

actor OpenAIReportingFixture {
    let month: Int
    var requests: [URLRequest] = []
    init(month: Int) { self.month = month }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        requests.append(request)
        let url = request.url!
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let after = params.first { $0.name == "after" }?.value
        let page = params.first { $0.name == "page" }?.value
        let json: String
        if url.path == "/v1/organization/projects" {
            json = after == nil ? #"{"data":[{"id":"proj_a","name":"Default"}],"has_more":true,"last_id":"proj_a"}"# : #"{"data":[{"id":"proj_b","name":"Other"}],"has_more":false}"#
        } else if url.path == "/v1/organization/projects/proj_a/api_keys" {
            json = after == nil ? #"{"data":[{"id":"key_tally","name":"Tally","created_at":1000}],"has_more":true,"last_id":"key_tally"}"# : #"{"data":[{"id":"key_split","name":"SplitTab","created_at":1001}],"has_more":false}"#
        } else if url.path == "/v1/organization/projects/proj_b/api_keys" {
            json = #"{"data":[{"id":"key_other","name":"Other","created_at":1002}],"has_more":false}"#
        } else if url.path == "/v1/organization/costs" {
            json = page == nil ? "{\"data\":[{\"start_time\":\(month-86400),\"results\":[{\"amount\":{\"value\":1.25,\"currency\":\"usd\"},\"api_key_id\":\"key_rotated\",\"project_id\":\"proj_a\"},{\"amount\":{\"value\":4,\"currency\":\"usd\"},\"api_key_id\":null}]}],\"has_more\":true,\"next_page\":\"second\"}" : "{\"data\":[{\"start_time\":\(month),\"results\":[{\"amount\":{\"value\":0.25,\"currency\":\"usd\"},\"api_key_id\":\"key_tally\"},{\"amount\":{\"value\":-0.1,\"currency\":\"usd\"},\"api_key_id\":\"key_tally\"}]}],\"has_more\":false}"
        } else {
            json = page == nil ? "{\"data\":[{\"start_time\":\(month),\"results\":[{\"api_key_id\":\"key_tally\",\"model\":\"test-model\",\"input_tokens\":100,\"output_tokens\":20,\"num_model_requests\":2}]}],\"has_more\":true,\"next_page\":\"second\"}" : "{\"data\":[{\"start_time\":\(month+86400),\"results\":[{\"api_key_id\":\"key_tally\",\"model\":\"test-model\",\"input_tokens\":50,\"output_tokens\":5,\"num_model_requests\":1}]}],\"has_more\":false}"
        }
        return (Data(json.utf8), 200)
    }
    func validRequests() -> Bool {
        requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.openai.com" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" } &&
        requests.filter { $0.url!.path.hasSuffix("costs") || $0.url!.path.hasSuffix("completions") }.allSatisfy {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "group_by" && $0.value == "api_key_id" }
        }
    }
}
