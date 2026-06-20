import ArgumentParser
import DeviceManager
import Foundation

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List audio input and output devices."
    )

    @Flag(name: .customLong("list-inputs"), help: "List only devices with input channels.")
    var listInputs = false

    @Flag(name: .customLong("list-outputs"), help: "List only devices with output channels.")
    var listOutputs = false

    @Flag(help: "Output as JSON for scripting.")
    var json = false

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        if listInputs && listOutputs {
            throw ValidationError("--list-inputs and --list-outputs are mutually exclusive; omit both to list all devices.")
        }
    }

    func run() throws {
        try runMapped(verbose: options.verbose) {
            let scope: DeviceScope = listInputs ? .input : listOutputs ? .output : .all
            let devices: [AudioDevice]
            do {
                devices = try DeviceManager.listDevices(scope: scope)
            } catch {
                throw HarkError.software("failed to enumerate devices: \(error)")
            }
            Log.verbose("found \(devices.count) device(s)")

            if json {
                print(try OutputFormatting.json(devices))
                return
            }
            guard !devices.isEmpty else {
                Log.verbose("no devices found")
                return
            }
            let rows = devices.map { device in
                [
                    device.uid,
                    device.name + (device.isDefaultInput ? " *" : ""),
                    String(device.inputChannels),
                    String(device.outputChannels),
                    device.sampleRates.map { String(Int($0)) }.joined(separator: ","),
                ]
            }
            print(OutputFormatting.table(header: ["UID", "NAME", "IN", "OUT", "RATES"], rows: rows))
        }
    }
}
