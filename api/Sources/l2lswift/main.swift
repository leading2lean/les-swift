/*
This is an example program for how to use the L2L Dispatch API to read and write data in the Dispatch system.

This code is written for Swift 5.x and runs on any platform supported by Swift. It was written and tested on Linux but
will work on any iOS device as well. The networking libraries in Swift are meant to be used asynchronously. This code
sample creates an extension to URLSession to make synchronous calls. This makes the sample code easier to read through.
However, if you use this code as a starting place for Dispatch integration you should use the standard asynchronous model.
Also, this code manually parses the json responses. Using the Codable protocol is a much better way to interface with
JSON result sets.

To use this code, you need to make sure you have a path to the swift compiler, then build the package from the same
directory as the Package.swift file:
    $ <path>/bin/swift build

To run this code, you would then run:
    $ .build/debug/l2lswift --dbg <your_server>.leading2lean.com <site> <username> <apikey>
*/
import Foundation
import FoundationNetworking
import ArgumentParser

// These are the standard datetime string formats that the Dispatch API supports
let API_MINUTE_FORMAT = "Y-MM-dd HH:mm"
let MINUTE_FORMATTER = DateFormatter()
MINUTE_FORMATTER.dateFormat = API_MINUTE_FORMAT

let API_SECONDS_FORMAT = "Y-MM-dd HH:mm:ss"
let SECONDS_FORMATTER = DateFormatter()
SECONDS_FORMATTER.dateFormat = API_SECONDS_FORMAT

func log(dbg: Bool, msg: String) {
    if dbg {
        print(msg)
    }
}

func respcheck(data: Data?, resp: URLResponse?, error: Error?) throws -> (error: Bool, [String: Any]) {
    guard let httpResponse = resp as? HTTPURLResponse else {
        throw "Expected an HTTPURLResponse"
    }
    if httpResponse.statusCode != 200 {
        throw "API call system failure, status: \(httpResponse.statusCode), error: \(String(describing:error))"
    }
    guard let rawData = data else {
        throw "API call system failure, did not receive any data"
    }
    let jsonRoot = try JSONSerialization.jsonObject(with: rawData, options: .mutableContainers)
    guard let jsonDict = jsonRoot as? [String: Any] else {
        throw "Can't convert json to dict"
    }
    guard let success = jsonDict["success"] as? Bool, success else {
        throw "API call failed, error: \(String(describing:jsonDict["error"]))"
    }
    return (true, jsonDict)
}

// Allow for a simple throw "<information>"
extension String: Error{}

// Swift best practices make it really difficult to use the networking api synchronously. This code uses an extension
//  to simulate a synchronous request
extension URLSession {
    func synchronousDataTask(urlrequest: URLRequest) -> (data: Data?, response: URLResponse?, error: Error?) {
        var data: Data?
        var response: URLResponse?
        var error: Error?

        let semaphore = DispatchSemaphore(value: 0)

        let dataTask = self.dataTask(with: urlrequest) {
            data = $0
            response = $1
            error = $2

            semaphore.signal()
        }
        dataTask.resume()

        _ = semaphore.wait(timeout: .distantFuture)

        return (data, response, error)
    }
}

func request(base: String, path: String, components: [URLQueryItem], post: Bool = false) -> (data: Data?, response: URLResponse?, error: Error?) {
    var urlComponents = URLComponents(string: base)!
    urlComponents.path = path
    urlComponents.queryItems = components
    var query: String? = ""
    if post {
        // grab the urlencoded items for the post data and reset the queryitems so they don't go on the url
        query = urlComponents.url!.query
        urlComponents.queryItems = []
    }
    var request = URLRequest(url: urlComponents.url!)
    if post {
        request.httpMethod = "POST"
        request.httpBody = Data(query!.utf8)
    }
    return URLSession.shared.synchronousDataTask(urlrequest: request)
}

func dcu(orig: [URLQueryItem], additions: [URLQueryItem]) -> [URLQueryItem] {
    var retval = orig
    retval.append(contentsOf: additions)
    return retval
}

struct L2LSwift: ParsableCommand {
    @Flag(help: "Print out verbose api output for debugging")
    var dbg: Bool

    @Argument(help: "Specify a hostname to use as the server")
    var server: String

    @Argument(help: "Specify the site to operate against")
    var site: String

    @Argument(help: "Specify the username for a user to use in the test")
    var user: String

    /* This example has you pass your API key in on the command line. Note that you should not do this in your
       production code. The API Key MUST be kept secret, and effective secrets management is outside the scope
       of this document. Make sure you don't hard code your api key into your source code, and usually you should
       expose it to your production code through an environment variable.
    */
    @Argument(help: "Specify the api key to use in the test")
    var apikey: String

    func run() throws {
        let baseUrl = "https://\(server)"
        var mainArgs: [URLQueryItem] = [URLQueryItem(name: "auth", value: apikey)]

        var components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "test_site", value: "true"),
            URLQueryItem(name: "site", value: site),
            URLQueryItem(name: "active", value: "true")
        ])

        var (data, response, error) = request(base: baseUrl, path: "/api/1.0/sites/", components: components)
        let (_, siteData) = try respcheck(data: data, resp: response, error: error)

        guard let testSiteArr = siteData["data"] as? [[String: Any]] else {
            throw "No data section found in result."
        }
        if testSiteArr.isEmpty {
            throw "No test site data in results: \(siteData)"
        }
        let testSite = testSiteArr[0]
        log(dbg: dbg, msg: "site found: \(String(describing:testSite["description"]!))")
        mainArgs.append(URLQueryItem(name: "site", value: site))

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Now let's find an area/line/machine to use
        let limit = 2
        var offset = 0
        var lastAreaData = [String: Any]()
        var finished = false
        repeat {
            components = dcu(orig: mainArgs, additions: [
                URLQueryItem(name: "active", value: "true"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset))
            ])

            (data, response, error) = request(base: baseUrl, path: "/api/1.0/areas/", components: components)
            let (_, areaData) = try respcheck(data: data, resp: response, error: error)

            guard let areaArr = areaData["data"] as? [[String: Any]] else {
                throw "No data section found in Area result."
            }
            // this means we hit the last page of possible results, so grab the last one in the list
            if areaArr.count < limit {
                finished = true
                if !areaArr.isEmpty {
                    lastAreaData = areaArr.last ?? [String: Any]()
                }
            } else {
                offset += areaArr.count
                lastAreaData = areaArr.last ?? [String: Any]()
            }
        } while !finished

        if lastAreaData.isEmpty {
            throw "Couldn't find active area to use."
        }
        log(dbg: dbg, msg: "Using area: \(String(describing: lastAreaData["code"]!))")

        guard let area_id = lastAreaData["id"] as! Int? else {
            throw "No area id found in results"
        }

        // Grab a Line for the Area
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "active", value: "true"),
            URLQueryItem(name: "area_id", value: String(area_id)),
            URLQueryItem(name: "enable_production", value: "true")
        ])

        (data, response, error) = request(base: baseUrl, path: "/api/1.0/lines/", components: components)
        let (_, lineResponse) = try respcheck(data: data, resp: response, error: error)

        guard let lineArr = lineResponse["data"] as? [[String: Any]] else {
            throw "No data section found in Line result."
        }
        if lineArr.isEmpty {
            throw "No data for the Line"
        }
        let lineData = lineArr[0]
        log(dbg: dbg, msg: "Using line: \(String(describing: lineData["code"]!))")

        guard let line_id = lineData["id"] as! Int? else {
            throw "No line id found in results"
        }

        // Grab a Machine for the Line
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "active", value: "true"),
            URLQueryItem(name: "line_id", value: String(line_id))
        ])

        (data, response, error) = request(base: baseUrl, path: "/api/1.0/machines/", components: components)
        let (_, machineResponse) = try respcheck(data: data, resp: response, error: error)

        guard let machineArr = machineResponse["data"] as? [[String: Any]] else {
            throw "No data section found in Machine result."
        }
        if machineArr.isEmpty {
            throw "No data for the machine"
        }
        let machineData = machineArr[0]
        let machineCode = machineData["code"] as! String
        let machineId = machineData["id"] as! Int
        log(dbg: dbg, msg: "Using machine: machineCode)")

        // Grab a Dispatch Type
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "active", value: "true")
        ])

        (data, response, error) = request(base: baseUrl, path: "/api/1.0/dispatchtypes/", components: components)
        let (_, dtResponse) = try respcheck(data: data, resp: response, error: error)

        guard let dtArr = dtResponse["data"] as? [[String: Any]] else {
            throw "No data section found in Dispatch Types result."
        }
        if dtArr.isEmpty {
            throw "No data for dispatch types"
        }
        let dtData = dtArr[0]
        log(dbg: dbg, msg: "Using Dispatch Type: \(String(describing: dtData["code"]!))")


        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Record a user clocking in to work on a line we found previously
        let lineCode = lineData["code"] as! String
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "active", value: "true"),
            URLQueryItem(name: "linecode", value: lineCode)
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/users/clock_in/\(user)/", components: components, post: true)
        let (_, clockinResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "User clocked in: " + String(describing: clockinResponse))

        // now clock out the user
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/users/clock_out/\(user)/", components: components, post: true)
        let (_, clockoutResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "User clocked out: " + String(describing: clockoutResponse))

        // We can record a user clockin session in the past by supplying a start and an end parameter. These datetime
        //  parameters in the API must be formatted consistently, and must represent the current time in the Site's
        //  timezone (NOT UTC) unless otherwise noted in the API documentation.
        var currentDate = Date()
        var dateComponent = DateComponents()
        dateComponent.day = -7
        var start = Calendar.current.date(byAdding: dateComponent, to: currentDate)!
        dateComponent.day = 0
        dateComponent.hour = 8
        let end = Calendar.current.date(byAdding: dateComponent, to: start)!

        components.append(contentsOf: [
            URLQueryItem(name: "start", value: MINUTE_FORMATTER.string(from:start)),
            URLQueryItem(name: "end", value: MINUTE_FORMATTER.string(from:end))
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/users/clock_in/\(user)/", components: components, post: true)
        let (_, clockinDateResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Created backdated clockin: " + String(describing: clockinDateResponse))

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Let's call specific api's for the machine we created. Here we set the machine's cycle count, and then
        //  we increment the machine's cycle count.
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "code", value: machineCode),
            URLQueryItem(name: "cyclecount", value: String(832))
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/machines/set_cycle_count/", components: components, post: true)
        let (_, setCycleCountResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Set machine cycle count: " + String(describing: setCycleCountResponse))

        // this simulates a high frequency machine where we make so many calls to this we don't care about tracking the
        //  lastupdated values for the machine cycle count.
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "code", value: machineCode),
            URLQueryItem(name: "skip_lastupdated", value: String(1)),
            URLQueryItem(name: "cyclecount", value: String(5))
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/machines/increment_cycle_count/", components: components, post: true)
        let (_, incrementResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Incremented machine cycle count: " + String(describing: incrementResponse))

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Let's create a Dispatch for the machine, to simulate an event that requires intervention
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "machine", value: String(machineId)),
            URLQueryItem(name: "description", value: "l2lsdk test dispatch"),
            URLQueryItem(name: "dispatchtype", value: String(dtData["id"] as! Int))
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/dispatches/open/", components: components, post: true)
        let (_, createDispatchResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Created open Dispatch: " + String(describing: createDispatchResponse))

        guard let dispDict = createDispatchResponse["data"] as? [String: Any] else {
            throw "No data section found in created Dispatch."
        }
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/dispatches/close/\(String(dispDict["id"] as! Int))/", components: mainArgs, post: true)
        let (_, closeDispatchResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Closed open Dispatch: " + String(describing: closeDispatchResponse))

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Let's add a Dispatch for the machine that represents an event that already happened and we just want to record it
        dateComponent = DateComponents()
        dateComponent.day = -60
        let reported = Calendar.current.date(byAdding: dateComponent, to: currentDate)!
        dateComponent.day = 0
        dateComponent.minute = 34
        let completed = Calendar.current.date(byAdding: dateComponent, to: reported)!
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "machinecode", value: String(machineCode)),
            URLQueryItem(name: "description", value: "l2lsdk test dispatch"),
            URLQueryItem(name: "dispatchtypecode", value: (dtData["code"] as! String)),
            URLQueryItem(name: "reported", value: SECONDS_FORMATTER.string(from:reported)),
            URLQueryItem(name: "completed", value: SECONDS_FORMATTER.string(from:completed))
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/dispatches/add/", components: components, post: true)
        let (_, addDispatchResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Created backdated Dispatch: " + String(describing: addDispatchResponse))

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Let's record some production data using the record_details api. This will create a 1 second pitch as we use now
        //  both start and end. Typically you should use a real time range for the start and end values.
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "linecode", value: (lineData["code"] as! String)),
            URLQueryItem(name: "productcode", value: "testproduct-" + String(Int(Date().timeIntervalSince1970))),
            URLQueryItem(name: "actual", value: String(Int.random(in: 10..<100))),
            URLQueryItem(name: "scrap", value: String(Int.random(in: 5..<20))),
            URLQueryItem(name: "operator_count", value: String(Int.random(in: 0..<10))),
            URLQueryItem(name: "start", value: "now"),
            URLQueryItem(name: "end", value: "now")
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/pitchdetails/record_details/", components: components, post: true)
        let (_, recordDetailsResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Recorded Pitch Details: " + String(describing: recordDetailsResponse))

        // Let's get the production reporting data for our line
        currentDate = Date()
        dateComponent = DateComponents()
        dateComponent.hour = -1
        dateComponent.day = -1
        start = Calendar.current.date(byAdding: dateComponent, to: currentDate)!
        components = dcu(orig: mainArgs, additions: [
            URLQueryItem(name: "linecode", value: (lineData["code"] as! String)),
            URLQueryItem(name: "start", value: MINUTE_FORMATTER.string(from:start)),
            URLQueryItem(name: "end", value: MINUTE_FORMATTER.string(from:currentDate)),
            URLQueryItem(name: "show_products", value: "true")
        ])
        (data, response, error) = request(base: baseUrl, path: "/api/1.0/reporting/production/daily_summary_data_by_line/", components: components, post: true)
        let (_, dailySummaryResponse) = try respcheck(data: data, resp: response, error: error)
        log(dbg: dbg, msg: "Daily Summary Details for line: " + String(describing: dailySummaryResponse))
    }
}

L2LSwift.main()
