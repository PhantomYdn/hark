import ArgumentParser
import DeviceManager
import Foundation

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List running applications whose audio can be captured.",
        discussion: """
            Lists processes registered with the audio HAL. These are valid \
            targets for per-application capture (hark --app). The \
            ACTIVE column shows which processes are currently playing or \
            recording audio.
            """
    )

    @Flag(help: "Output as JSON for scripting.")
    var json = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            let apps: [CapturableApp]
            do {
                apps = try DeviceManager.listCapturableApps()
            } catch {
                throw HarkError.software("failed to enumerate audio processes: \(error)")
            }
            Log.verbose("found \(apps.count) audio process(es)")

            if json {
                print(try OutputFormatting.json(apps))
                return
            }
            guard !apps.isEmpty else {
                Log.verbose("no audio processes found")
                return
            }
            let rows = apps.map { app in
                [
                    String(app.pid),
                    app.name,
                    app.bundleID.isEmpty ? "-" : app.bundleID,
                    app.audioActive ? "yes" : "-",
                ]
            }
            print(OutputFormatting.table(header: ["PID", "NAME", "BUNDLE ID", "ACTIVE"], rows: rows))
        }
    }
}
