@testable import ArinCore
import Foundation
import Testing

@Suite struct RemoteHostTests {
    @Test func validatesSSHTargets() {
        #expect(RemoteHost.isValidTarget("vm"))
        #expect(RemoteHost.isValidTarget("sozercan@10.0.0.5"))
        #expect(RemoteHost.isValidTarget("dev-box.internal"))
        #expect(!RemoteHost.isValidTarget(""))
        #expect(!RemoteHost.isValidTarget("-oProxyCommand=evil"))
        #expect(!RemoteHost.isValidTarget("vm; rm -rf /"))
        #expect(!RemoteHost.isValidTarget("vm $(whoami)"))
        #expect(!RemoteHost.isValidTarget("host name"))
    }

    @Test func parsesSSHConfigHosts() {
        let config = """
        # comment
        Host vm build-box
            HostName 10.0.0.2

        Host *.internal !bastion
            User ops

        Host gpu-1
            User root

        Host vm
            Port 2222
        """
        #expect(SSHConfig.parseHosts(config) == ["vm", "build-box", "gpu-1"])
    }

    @Test func quotesShellArgumentsSafely() {
        #expect(SSHTransport.shellQuote("simple") == "'simple'")
        #expect(SSHTransport.shellQuote("a'b") == "'a'\\''b'")
    }
}

@Suite struct RemoteGuardrailTests {
    let guardrails = Guardrails.remote(home: "/home/dev", mountPoints: ["/", "/mnt", "/home/dev/mounted"])

    @Test func allowsRemoteCachesAndTemp() throws {
        try guardrails.check("/home/dev/.cache/go-build")
        try guardrails.check("/home/dev/go/pkg/mod")
        try guardrails.check("/tmp/scratch")
    }

    @Test func refusesRemoteProtectedAndOutsidePaths() {
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev/.cache") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev/.ssh/id_ed25519") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev/.kube/config") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev/.azure/tokens") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/etc/passwd") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev/mounted/cache") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/DEV/.cache/go-build") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/home/dev/Library/Messages/Attachments") }
        #expect(throws: Guardrails.Violation.self) { try guardrails.check("/tmp") }
    }

    @Test func allowsRemoteCachesWhenHomeIsSeparateMount() throws {
        let separateHome = Guardrails.remote(home: "/home/dev", mountPoints: ["/", "/home", "/home/dev/mounted", "/tmp/cache", "/var/mounted"])
        try separateHome.check("/home/dev/.cache/go-build")
        try separateHome.check("/tmp/scratch")
        #expect(throws: Guardrails.Violation.self) { try separateHome.check("/home/dev/mounted/cache") }
        #expect(throws: Guardrails.Violation.self) { try separateHome.check("/tmp/cache") }
        #expect(throws: Guardrails.Violation.self) { try separateHome.check("/tmp/cache/sub") }

        let varHome = Guardrails.remote(home: "/var/lib/dev", mountPoints: ["/"])
        try varHome.check("/var/lib/dev/.cache/go-build")
        #expect(throws: Guardrails.Violation.self) { try varHome.check("/var/lib/dev/.ssh/id_ed25519") }
        #expect(throws: Guardrails.Violation.self) { try varHome.check("/var/lib/dev/.aws/credentials") }
        #expect(throws: Guardrails.Violation.self) { try varHome.check("/var/lib/dev/.gnupg/secring") }
    }

    @Test func failsClosedWhenRemoteMountsAreUnknown() {
        let unknown = Guardrails.remote(home: "/home/dev", mountPoints: nil)
        #expect(throws: Guardrails.Violation.self) { try unknown.check("/home/dev/.cache/go-build") }
    }

    @Test func restrictsPipAndKindCommands() {
        #expect(Guardrails.allows(CommandSpec("pip", ["cache", "purge"])))
        #expect(Guardrails.allows(CommandSpec("pip3", ["cache", "purge"])))
        #expect(!Guardrails.allows(CommandSpec("pip", ["install", "foo"])))
        #expect(Guardrails.allows(CommandSpec("kind", ["delete", "cluster", "--name", "demo-1"])))
        #expect(!Guardrails.allows(CommandSpec("kind", ["delete", "clusters", "--all"])))
        #expect(!Guardrails.allows(CommandSpec("kind", ["delete", "cluster", "--name", "../bad"])))
    }
}

@Suite struct RemoteParsingTests {
    @Test func parsesProbeOutput() throws {
        let sample = """
        __ARIN_OS__=Linux
        __ARIN_HOST__=dev-vm
        __ARIN_HOME__=/home/dev
        __ARIN_UID__=1000
        __ARIN_DF__
        /dev/sdb1 1500000000 1400000000 100000000 94% /
        __ARIN_TOOLS__
        docker
        go
        kind
        __ARIN_SUDO__
        yes
        __ARIN_MOUNTS__
        /
        /mnt
        __ARIN_PS__
        sshd
        go
        __ARIN_LSOF__
        p1234
        n/home/dev/.cache/go-build/00/abc
        __ARIN_LSOF_OK__=yes
        __ARIN_END__
        """
        let env = try RemoteEnvironment.parse(sample, host: RemoteHost(target: "vm"))
        #expect(env.os == "Linux")
        #expect(env.hostname == "dev-vm")
        #expect(env.home == "/home/dev")
        #expect(env.disk.totalBytes == 1_500_000_000 * 1024)
        #expect(env.disk.freeBytes == 100_000_000 * 1024)
        #expect(env.tools == ["docker", "go", "kind"])
        #expect(env.hasPasswordlessSudo)
        #expect(env.mountPoints == ["/", "/mnt"])
        #expect(env.systemState.isRunning("go"))
        #expect(env.systemState.isBusy("/home/dev/.cache/go-build"))
        #expect(env.openFilesKnown)
    }

    @Test func parsesDockerFallbackWhenSystemDfTimesOut() {
        let sample = """
        __DOCKER_CONTEXT__=default
        __DOCKER_ENDPOINT__=unix:///var/run/docker.sock
        __DOCKER_INFO__
        28.5.2-1
        __DOCKER_BUILDX_DU__
        Shared:\t\t53.54GB
        Private:\t119.4GB
        Reclaimable:\t171.6GB
        Total:\t\t172.9GB
        __DOCKER_BUILDX_LS__
        default*
        dev
        __DOCKER_DF__
        __DF_TIMEOUT__
        __DOCKER_VOLUMES__
        buildx_buildkit_oldbuilder0_state\t2026-11-01T00:00:00Z
        postgres-data\t2026-11-02T00:00:00Z
        __DOCKER_EXITED__
        5
        """
        let output = RemoteScanner.parseDockerScan(sample, host: RemoteHost(target: "vm"))
        let buildCache = output.candidates.first { $0.ruleID == "remote.docker.build-cache" }
        #expect(buildCache?.bytes == 171_600_000_000)
        #expect(buildCache?.risk == .safe)
        #expect(buildCache?.action == .commands([CommandSpec("docker", ["--context", "default", "builder", "prune", "-af"])]))

        let volumes = output.candidates.filter { $0.ruleID == "remote.docker.volume" }
        #expect(volumes.count == 2)
        #expect(volumes.first { $0.title.contains("oldbuilder") }?.risk == .safe)
        #expect(volumes.first { $0.title.contains("postgres-data") }?.risk == .review)
        #expect(volumes.first { $0.title.contains("postgres-data") }?.action == .commands([CommandSpec("docker", ["--context", "default", "volume", "rm", "postgres-data"])]))
        #expect(output.insights.contains { $0.id == "remote-docker-df-timeout" })
        #expect(output.insights.contains { $0.id == "remote-docker-exited" })
    }

    @Test func skipsNonLocalDockerContextEndpoint() {
        let sample = """
        __DOCKER_CONTEXT__=shared-builder
        __DOCKER_ENDPOINT__=ssh://other-host
        """
        let output = RemoteScanner.parseDockerScan(sample, host: RemoteHost(target: "vm"))
        #expect(output.candidates.isEmpty)
        #expect(output.insights.contains { $0.id == "remote-docker-nonlocal-context" })
    }

    @Test func huggingFaceRulePreservesCredentials() {
        let spec = RemoteScanner.cacheSpecs.first { $0.id == "remote.huggingface.cache" }
        #expect(spec?.relativePaths == [".cache/huggingface/hub"])
    }

    @Test func parsesCacheMeasurements() {
        let sample = "remote.go.build-cache\t52428800\t1700000000\t/home/dev/.cache/go-build\n"
            + "remote.pip.cache\t1048576\t1700000100\t/home/dev/.cache/pip\n"
        let parsed = RemoteScanner.parseCacheMeasurements(sample)
        #expect(parsed["remote.go.build-cache"]?.first?.bytes == Int64(52_428_800) * 1024)
        #expect(parsed["remote.pip.cache"]?.first?.path == "/home/dev/.cache/pip")
    }
}

@Suite struct RemoteExecutorTests {
    private struct StubRunner: CommandRunner {
        let handler: @Sendable (String, [String], String?) -> ShellResult
        func which(_ name: String) -> String? { "/usr/bin/\(name)" }
        func run(_ executable: String, _ arguments: [String], cwd: String?, input: String?,
                 environment: [String: String], timeout: TimeInterval) async -> ShellResult {
            handler(executable, arguments, input)
        }
    }

    @Test func skipsProtectedPathAndUnlistedCommandOverSSH() async {
        let probeOutput = """
        __ARIN_OS__=Linux
        __ARIN_HOST__=vm
        __ARIN_HOME__=/home/dev
        __ARIN_UID__=1000
        __ARIN_DF__
        /dev/sdb1 1000000 500000 500000 50% /
        __ARIN_TOOLS__
        docker
        __ARIN_SUDO__
        no
        __ARIN_MOUNTS__
        /
        __ARIN_PS__
        sshd
        __ARIN_LSOF__
        n/home/dev/.bashrc
        __ARIN_LSOF_OK__=yes
        __ARIN_END__
        """
        let runner = StubRunner { _, _, input in
            if let input, input.contains("__ARIN_OS__") {
                return ShellResult(status: 0, stdout: probeOutput, stderr: "", timedOut: false)
            }
            if let input, input.contains("df -Pk") {
                return ShellResult(status: 0, stdout: "/dev/sdb1 1000000 500000 500000 50% /\n", stderr: "", timedOut: false)
            }
            return ShellResult(status: 0, stdout: "", stderr: "", timedOut: false)
        }
        let report = await Shell.$runner.withValue(runner) {
            let executor = RemoteExecutor(host: RemoteHost(target: "vm"), keepListURL: nil)
            let guarded = Candidate(
                ruleID: "t", title: "ssh keys", detail: "", category: .devCaches, level: .quick, risk: .safe,
                bytes: 100, paths: ["/home/dev/.ssh/id_ed25519"], action: .delete(["/home/dev/.ssh/id_ed25519"])
            )
            let unlisted = Candidate(
                ruleID: "t2", title: "bad cmd", detail: "", category: .devCaches, level: .quick, risk: .safe,
                bytes: 100, paths: [], action: .commands([CommandSpec("rm", ["-rf", "/"])])
            )
            return await executor.run([guarded, unlisted])
        }
        #expect(report.items.count == 2)
        #expect(report.items[0].status == .skipped)
        #expect(report.items[1].status == .skipped)
    }

    @Test func skipsRemotePathWhoseParentSymlinksIntoMount() async {
        let probeOutput = """
        __ARIN_OS__=Linux
        __ARIN_HOST__=vm
        __ARIN_HOME__=/home/dev
        __ARIN_UID__=1000
        __ARIN_DF__
        /dev/sdb1 1000000 500000 500000 50% /
        __ARIN_TOOLS__
        __ARIN_SUDO__
        no
        __ARIN_MOUNTS__
        /
        /mnt
        __ARIN_PS__
        sshd
        __ARIN_LSOF__
        n/home/dev/.bashrc
        __ARIN_LSOF_OK__=yes
        __ARIN_END__
        """
        let runner = StubRunner { _, _, input in
            if let input, input.contains("__ARIN_OS__") {
                return ShellResult(status: 0, stdout: probeOutput, stderr: "", timedOut: false)
            }
            if let input, input.contains("readlink -f") {
                return ShellResult(status: 0, stdout: "/mnt/shared-cache\n", stderr: "", timedOut: false)
            }
            if let input, input.contains("df -Pk") {
                return ShellResult(status: 0, stdout: "/dev/sdb1 1000000 500000 500000 50% /\n", stderr: "", timedOut: false)
            }
            return ShellResult(status: 0, stdout: "", stderr: "", timedOut: false)
        }
        let report = await Shell.$runner.withValue(runner) {
            let executor = RemoteExecutor(host: RemoteHost(target: "vm"), keepListURL: nil)
            let symlinked = Candidate(
                ruleID: "remote.yarn.cache", title: "Yarn cache", detail: "", category: .devCaches, level: .quick, risk: .safe,
                bytes: 100, paths: ["/home/dev/.cache/yarn"], action: .delete(["/home/dev/.cache/yarn"])
            )
            return await executor.run([symlinked])
        }
        #expect(report.items.count == 1)
        #expect(report.items[0].status == .skipped)
    }

    @Test func refusesNativeCommandWhoseEffectiveCacheIsOnMountOrRemoteDocker() async {
        let probeOutput = """
        __ARIN_OS__=Linux
        __ARIN_HOST__=vm
        __ARIN_HOME__=/home/dev
        __ARIN_UID__=1000
        __ARIN_DF__
        /dev/sdb1 1000000 500000 500000 50% /
        __ARIN_TOOLS__
        go
        docker
        __ARIN_SUDO__
        no
        __ARIN_MOUNTS__
        /
        /mnt
        __ARIN_PS__
        sshd
        __ARIN_LSOF__
        n/home/dev/.bashrc
        __ARIN_LSOF_OK__=yes
        __ARIN_END__
        """
        let runner = StubRunner { _, _, input in
            if let input, input.contains("__ARIN_OS__") {
                return ShellResult(status: 0, stdout: probeOutput, stderr: "", timedOut: false)
            }
            if let input, input.contains("go env GOMODCACHE") {
                return ShellResult(status: 0, stdout: "/mnt/shared go mod\n", stderr: "", timedOut: false)
            }
            if let input, input.contains("__EP__=") && input.contains("__VCREATED__=") {
                return ShellResult(status: 0, stdout: "__EP__=ssh://other-daemon\n__ID__=daemon-1\n__VCREATED__=2026-11-01T00:00:00Z\n", stderr: "", timedOut: false)
            }
            if let input, input.contains("__NODES__=") {
                return ShellResult(status: 0, stdout: "__CTX__=default\n__EP__=unix:///var/run/docker.sock\n__ID__=daemon-2\n__NODES__=abc123\n", stderr: "", timedOut: false)
            }
            if let input, input.contains("readlink -f") {
                return ShellResult(status: 0, stdout: "/home/dev/go/pkg/mod\n", stderr: "", timedOut: false)
            }
            if let input, input.contains("df -Pk") {
                return ShellResult(status: 0, stdout: "/dev/sdb1 1000000 500000 500000 50% /\n", stderr: "", timedOut: false)
            }
            Issue.record("Unexpected destructive command ran: \(input ?? "")")
            return ShellResult(status: 1, stdout: "", stderr: "unexpected", timedOut: false)
        }
        let report = await Shell.$runner.withValue(runner) {
            let executor = RemoteExecutor(host: RemoteHost(target: "vm"), keepListURL: nil)
            let goMod = Candidate(
                ruleID: "remote.go.mod-cache", title: "Go module cache", detail: "", category: .devCaches, level: .standard, risk: .safe,
                bytes: 100, paths: ["/home/dev/go/pkg/mod"], action: .commands([CommandSpec("go", ["clean", "-modcache"])])
            )
            let dockerVol = Candidate(
                ruleID: "remote.docker.volume", key: "vm:remote-ctx:daemon-1:2026-11-01T00:00:00Z:v1",
                title: "Docker volume v1", detail: "", category: .containers, level: .standard, risk: .review,
                bytes: 0, paths: [], action: .commands([CommandSpec("docker", ["--context", "remote-ctx", "volume", "rm", "v1"])])
            )
            let kindCluster = Candidate(
                ruleID: "remote.kind.cluster", key: "vm:kind:default:daemon-1:abc123:demo",
                title: "kind cluster: demo", detail: "", category: .containers, level: .deep, risk: .review,
                bytes: 0, paths: [], action: .commands([CommandSpec("kind", ["delete", "cluster", "--name", "demo"])])
            )
            return await executor.run([goMod, dockerVol, kindCluster])
        }
        #expect(report.items.count == 3)
        #expect(report.items[0].status == .skipped)
        #expect(report.items[0].message.contains("now targets"))
        #expect(report.items[1].status == .skipped)
        #expect(report.items[1].message.contains("non-local endpoint"))
        #expect(report.items[2].status == .skipped)
        #expect(report.items[2].message.contains("changed since the scan"))
    }

    @Test func refusesCleanupWhenRemoteHostIdentityChanges() async {
        let probeOutput = """
        __ARIN_OS__=Linux
        __ARIN_HOST__=other-vm
        __ARIN_HOME__=/home/dev
        __ARIN_UID__=1000
        __ARIN_DF__
        /dev/sdb1 1000000 500000 500000 50% /
        __ARIN_TOOLS__
        docker
        __ARIN_SUDO__
        no
        __ARIN_MOUNTS__
        /
        __ARIN_PS__
        sshd
        __ARIN_LSOF__
        n/home/dev/.bashrc
        __ARIN_LSOF_OK__=yes
        __ARIN_END__
        """
        let runner = StubRunner { _, _, _ in
            ShellResult(status: 0, stdout: probeOutput, stderr: "", timedOut: false)
        }
        let report = await Shell.$runner.withValue(runner) {
            let executor = RemoteExecutor(
                host: RemoteHost(target: "vm"),
                expectedIdentity: "1000@original-vm:/home/dev",
                keepListURL: nil
            )
            let dockerVol = Candidate(
                ruleID: "remote.docker.volume", title: "Docker volume v1", detail: "", category: .containers, level: .standard, risk: .review,
                bytes: 0, paths: [], action: .commands([CommandSpec("docker", ["--context", "default", "volume", "rm", "v1"])])
            )
            return await executor.run([dockerVol])
        }
        #expect(report.items.count == 1)
        #expect(report.items[0].status == .skipped)
    }
}
