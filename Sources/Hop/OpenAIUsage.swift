import Foundation
import Security
import SwiftUI
import Charts

struct OpenAITrackedKey: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var projectID: String
    var projectName: String
    var createdAt: Int
    var historical = false
    var expiresAt: Int? = nil
    func selectable(at date: Date = Date()) -> Bool {
        !historical && (expiresAt.map { Double($0) > date.timeIntervalSince1970 } ?? true)
    }
}
struct OpenAICostDay: Codable, Equatable {
    var day: Int
    var keyID: String
    var amount: Decimal
}
struct OpenAIModelUsage: Codable, Equatable {
    var keyID: String
    var model: String
    var requests: Int
    var input: Int
    var output: Int
}
struct OpenAIUsageState: Codable {
    var connected = false
    var keys: [OpenAITrackedKey] = []
    var links: [String: Set<String>] = [:]
    var costs: [OpenAICostDay] = []
    var usage: [OpenAIModelUsage] = []
    var usageMonth: Int?
    var historyFrom: Int?
    var updatedAt: Date?
    var unattributedCosts = false
    var historyHasGaps = false
}
struct OpenAISpending {
    var month: Decimal?
    var total: Decimal
}
func openAIUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
func openAIMonthStart(_ date: Date) -> Int {
    Int(openAIUTCCalendar().dateInterval(of: .month, for: date)!.start.timeIntervalSince1970)
}
func openAIHistoryStart(_ date: Date) -> Int {
    let calendar = openAIUTCCalendar()
    // Stay within the dashboard's available year of history, aligned to UTC days.
    return Int(calendar.startOfDay(for: calendar.date(byAdding: .year, value: -1, to: date)!).addingTimeInterval(86400).timeIntervalSince1970)
}
func openAIMoney(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = value != 0 && abs(NSDecimalNumber(decimal: value).doubleValue) < 0.01 ? 4 : 2
    if value > 0 && value < Decimal(string: "0.0001")! { return "<$0.0001" }
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
}
func openAIMoney(_ value: Decimal?) -> String {
    guard let value else { return "—" }
    return openAIMoney(value)
}
func openAISpending(_ state: OpenAIUsageState, projectID: String, now: Date = Date()) -> OpenAISpending? {
    guard state.updatedAt != nil, let ids = state.links[projectID], !ids.isEmpty else { return nil }
    let monthStart = openAIMonthStart(now)
    let rows = state.costs.filter { ids.contains($0.keyID) }
    return OpenAISpending(month: state.updatedAt!.timeIntervalSince1970 >= Double(monthStart) ? rows.filter { $0.day >= monthStart }.reduce(0) { $0 + $1.amount } : nil,
                          total: rows.reduce(0) { $0 + $1.amount })
}
func mergeOpenAICosts(_ old: [OpenAICostDay], _ fresh: [OpenAICostDay], since: Int) -> [OpenAICostDay] {
    // Replace the entire fetched window, including days revised down to zero.
    old.filter { $0.day < since } + fresh
}

enum OpenAIUsageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

enum OpenAIKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pratick.hop.openai",
         kSecAttrAccount as String: "admin-api-key"]
    }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw OpenAIUsageError.message("OpenAI key unavailable. Reconnect in General Settings.")
        }
        return key
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw OpenAIUsageError.message("Couldn’t save the OpenAI key in Keychain.")
            }
        } else if status != errSecSuccess {
            throw OpenAIUsageError.message("Couldn’t update the OpenAI key in Keychain.")
        }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIUsageError.message("Couldn’t remove the OpenAI key from Keychain.")
        }
    }
}

private final class OpenAINoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct OpenAIClient {
    typealias Transport = (URLRequest) async throws -> (Data, Int)
    var key: String
    var transport: Transport
    private static let session = URLSession(configuration: .ephemeral, delegate: OpenAINoRedirects(), delegateQueue: nil)
    init(key: String, transport: Transport? = nil) {
        self.key = key
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents(string: "https://api.openai.com/v1/organization/" + path)!
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else {
            let message: String
            switch status {
            case 401: message = "OpenAI rejected the key. Connect a valid Admin API key in General Settings."
            case 403: message = "This Admin API key lacks access to projects, API keys, or usage and costs. Check its permissions."
            case 429: message = "OpenAI’s rate limit was reached. Try refreshing later."
            default: message = "OpenAI usage is unavailable (HTTP \(status)). Try refreshing later."
            }
            // Never display raw response bodies: they may include account or credential details.
            throw OpenAIUsageError.message(message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OpenAIUsageError.message("OpenAI returned an unexpected reporting response. Cached figures are unchanged.") }
    }
    struct ListPage<T: Decodable>: Decodable {
        var data: [T]
        var has_more: Bool
        var last_id: String?
    }
    struct RemoteProject: Decodable { var id: String; var name: String? }
    struct RemoteKey: Decodable { var id: String; var name: String; var created_at: Int; var expires_at: Int? }
    func list<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        var items: [T] = [], cursor: String?, seen = Set<String>()
        repeat {
            var params = query + [URLQueryItem(name: "limit", value: "100")]
            if let cursor { params.append(URLQueryItem(name: "after", value: cursor)) }
            let page: ListPage<T> = try await get(path, query: params)
            items += page.data
            guard page.has_more else { return items }
            guard let next = page.last_id, seen.insert(next).inserted else { throw OpenAIUsageError.message("OpenAI returned an incomplete project/key list. Try again.") }
            cursor = next
        } while true
    }
    func catalog() async throws -> [OpenAITrackedKey] {
        let projects: [RemoteProject] = try await list("projects", query: [URLQueryItem(name: "include_archived", value: "true")])
        var keys: [OpenAITrackedKey] = []
        for project in projects {
            guard project.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw OpenAIUsageError.message("OpenAI returned an invalid project identifier.")
            }
            let remote: [RemoteKey] = try await list("projects/\(project.id)/api_keys", query: [URLQueryItem(name: "owner_project_access", value: "any")])
            keys += remote.map { OpenAITrackedKey(id: $0.id, name: $0.name, projectID: project.id, projectName: project.name ?? project.id, createdAt: $0.created_at, expiresAt: $0.expires_at) }
        }
        return keys
    }
    struct Bucket<T: Decodable>: Decodable { var start_time: Int; var results: [T] }
    struct UsagePage<T: Decodable>: Decodable { var data: [Bucket<T>]; var has_more: Bool; var next_page: String? }
    struct Cost: Decodable {
        struct Amount: Decodable { var value: Decimal; var currency: String }
        var amount: Amount?
        var api_key_id: String?
        var project_id: String?
    }
    struct Usage: Decodable {
        var api_key_id: String?
        var model: String?
        var input_tokens: Int
        var output_tokens: Int
        var num_model_requests: Int
    }
    func buckets<T: Decodable>(_ path: String, since: Int, until: Int, groups: [String], limit: Int) async throws -> [Bucket<T>] {
        var result: [Bucket<T>] = [], cursor: String?, seen = Set<String>()
        repeat {
            var params = [URLQueryItem(name: "start_time", value: String(since)), URLQueryItem(name: "end_time", value: String(until)),
                          URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: String(limit))]
            params += groups.map { URLQueryItem(name: "group_by", value: $0) }
            if let cursor { params.append(URLQueryItem(name: "page", value: cursor)) }
            let page: UsagePage<T> = try await get(path, query: params)
            result += page.data
            guard page.has_more else { return result }
            guard let next = page.next_page, seen.insert(next).inserted else { throw OpenAIUsageError.message("OpenAI returned incomplete usage history. Cached figures are unchanged.") }
            cursor = next
        } while true
    }
    struct Report {
        var costs: [OpenAICostDay]
        var usage: [OpenAIModelUsage]
        var historicalKeys: [OpenAITrackedKey]
        var unattributed: Bool
    }
    func report(since: Int, now: Date) async throws -> Report {
        let until = Int(now.timeIntervalSince1970)
        let costs: [Bucket<Cost>] = try await buckets("costs", since: since, until: until, groups: ["api_key_id", "project_id"], limit: 180)
        let usage: [Bucket<Usage>] = try await buckets("usage/completions", since: openAIMonthStart(now), until: until, groups: ["api_key_id", "model"], limit: 31)
        var rows: [OpenAICostDay] = [], historical: [String: OpenAITrackedKey] = [:], unattributed = false
        for bucket in costs {
            for cost in bucket.results {
                guard let amount = cost.amount else { throw OpenAIUsageError.message("A spending amount is missing. Cached figures are unchanged.") }
                guard amount.currency.lowercased() == "usd" else { throw OpenAIUsageError.message("OpenAI returned a currency other than USD. Cached figures are unchanged.") }
                guard let keyID = cost.api_key_id else { if amount.value != 0 { unattributed = true }; continue }
                rows.append(OpenAICostDay(day: bucket.start_time, keyID: keyID, amount: amount.value))
                historical[keyID] = OpenAITrackedKey(id: keyID, name: "Historical key", projectID: cost.project_id ?? "", projectName: cost.project_id ?? "Historical usage", createdAt: bucket.start_time, historical: true)
            }
        }
        return Report(costs: rows, usage: usage.flatMap { bucket in bucket.results.compactMap { value in
            guard let keyID = value.api_key_id else { return nil }
            return OpenAIModelUsage(keyID: keyID, model: value.model ?? "Unknown model", requests: value.num_model_requests, input: value.input_tokens, output: value.output_tokens)
        } }, historicalKeys: Array(historical.values), unattributed: unattributed)
    }
}

@MainActor final class OpenAIUsageStore: ObservableObject {
    @Published private(set) var state = OpenAIUsageState()
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    private let file: URL
    private let automaticRefreshEnabled: Bool
    private var attempt: Date?
    init(support: URL, automaticRefreshEnabled: Bool = true) {
        self.automaticRefreshEnabled = automaticRefreshEnabled
        file = support.appendingPathComponent("openai-usage.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(OpenAIUsageState.self, from: data) { state = saved }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
    func connect(_ supplied: String) async -> Bool {
        guard !busy else { return false }
        let key = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { error = "Enter an Admin API key."; return false }
        busy = true; error = ""
        defer { busy = false }
        do {
            let client = OpenAIClient(key: key)
            let keys = try await client.catalog()
            try OpenAIKeychain.save(key)
            // A replacement credential may belong to another organization: never mix their totals.
            state = OpenAIUsageState(); state.connected = true; state.keys = keys
            try save()
            try await sync(client, catalog: keys)
            return true
        } catch { self.error = error.localizedDescription; return state.connected }
    }
    func disconnect() {
        guard !busy else { return }
        do {
            try OpenAIKeychain.remove()
            state = OpenAIUsageState(); error = ""; attempt = nil
            try save()
        } catch { self.error = error.localizedDescription }
    }
    func refresh(force: Bool = false) async {
        guard state.connected, !busy, force || automaticRefreshEnabled,
              force || attempt.map({ Date().timeIntervalSince($0) >= 900 }) ?? true else { return }
        busy = true; error = ""; attempt = Date()
        defer { busy = false }
        do {
            let client = OpenAIClient(key: try OpenAIKeychain.read())
            let catalog = try await client.catalog()
            try await sync(client, catalog: catalog)
        } catch { self.error = error.localizedDescription }
    }
    private func sync(_ client: OpenAIClient, catalog: [OpenAITrackedKey]) async throws {
        let now = Date(), start = openAIHistoryStart(Date())
        let report = try await client.report(since: start, now: now)
        var next = state
        var keys = Dictionary(uniqueKeysWithValues: state.keys.map { value in
            var key = value; key.historical = true
            return (key.id, key)
        })
        for key in report.historicalKeys where keys[key.id] == nil { keys[key.id] = key }
        for key in catalog { keys[key.id] = key }
        next.keys = keys.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        next.costs = mergeOpenAICosts(state.costs, report.costs, since: start)
        next.usage = report.usage; next.usageMonth = openAIMonthStart(now)
        next.historyHasGaps = state.historyHasGaps || (state.updatedAt.map { Int($0.timeIntervalSince1970) < start } ?? false)
        next.historyFrom = min(state.historyFrom ?? start, start)
        next.updatedAt = now; next.unattributedCosts = report.unattributed
        // Save before publishing so a failed write cannot appear as a successful refresh.
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        state = next; attempt = now
    }
    func link(_ project: Project, keyID: String, enabled: Bool) {
        if enabled { state.links[project.id, default: []].insert(keyID) }
        else { state.links[project.id]?.remove(keyID) }
        do { try save() } catch { self.error = error.localizedDescription }
    }
    func spending(_ project: Project) -> OpenAISpending? { openAISpending(state, projectID: project.id) }
    func linked(_ project: Project) -> Set<String> { state.links[project.id] ?? [] }
    var historyLabel: String {
        guard let since = state.historyFrom else { return "History not synced yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let date = formatter.string(from: Date(timeIntervalSince1970: Double(since)))
        return "History since \(date)." + (state.historyHasGaps ? " Some older periods are unavailable." : "")
    }
}

struct OpenAIReportingFooter: View {
    @ObservedObject var usage: OpenAIUsageStore
    var body: some View {
        if let refreshed = usage.state.updatedAt {
            HStack(alignment: .top, spacing: 32) {
                if let since = usage.state.historyFrom {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("History since").font(.caption).foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: Double(since)), format: .dateTime.month(.abbreviated).day().year())
                            .font(.system(size: 11)).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last refreshed").font(.caption).foregroundStyle(.secondary)
                    Text(refreshed, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11))
                }
                Spacer(minLength: 0)
            }
            .help(usage.state.historyHasGaps ? "Some older periods are unavailable. Monthly totals use UTC." : "Monthly totals use UTC.")
        }
    }
}

struct OpenAIConnectionSettings: View {
    @ObservedObject var usage: OpenAIUsageStore
    @State private var key = ""
    var body: some View {
        GeneralSettingsCard(title: "OpenAI", subtitle: "Spending & usage", icon: "chart.bar",
                            headerLink: ("Open billing", URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)) {
            if usage.state.connected {
                HStack {
                    Text("Connected").foregroundStyle(.secondary)
                        .help("Admin key stored in macOS Keychain")
                    Spacer()
                    Button("Refresh") { Task { await usage.refresh(force: true) } }.disabled(usage.busy)
                    Button("Disconnect") { usage.disconnect() }.disabled(usage.busy)
                        .help("Disconnect and clear saved key links and reporting history")
                }
                Text("Link keys in each project’s Configure tab.")
                    .font(.caption).foregroundStyle(.secondary)
                OpenAIReportingFooter(usage: usage)
            } else {
                SecureField("OpenAI Admin API key", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Link("Create an Admin API key", destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
                    Spacer()
                    Button("Connect") {
                        let supplied = key; key = ""
                        Task { _ = await usage.connect(supplied) }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || usage.busy)
                }
                Text("Saved in Keychain. Refreshes automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if usage.busy { HStack { ProgressView().controlSize(.mini); Text("Refreshing…").font(.caption) } }
            if !usage.error.isEmpty { Text(usage.error).font(.caption).foregroundStyle(.orange) }
            if usage.state.unattributedCosts {
                Text("Unassigned costs aren’t included in app totals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct OpenAIProjectLinkSettings: View {
    @ObservedObject var usage: OpenAIUsageStore
    let project: Project
    @State private var filter = ""
    @State private var showInactive = false
    private var visibleKeys: [OpenAITrackedKey] { usage.state.keys.filter { showInactive || $0.selectable() } }
    var body: some View {
        GeneralSettingsCard(title: "OpenAI", subtitle: "Keys for this app", icon: "chart.bar") {
            if usage.state.connected {
                HStack {
                    Toggle("Show inactive keys", isOn: $showInactive).toggleStyle(.checkbox)
                    Spacer()
                    Button("Refresh keys") { Task { await usage.refresh(force: true) } }.disabled(usage.busy)
                }
                if !visibleKeys.isEmpty {
                    TextField("Find an API key", text: $filter).textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(visibleKeys.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.id.localizedCaseInsensitiveContains(filter) }) { key in
                                Toggle(isOn: Binding(get: { usage.linked(project).contains(key.id) }, set: { usage.link(project, keyID: key.id, enabled: $0) })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(key.name).font(.system(size: 12, weight: .medium))
                                            if !key.selectable() {
                                                Text(key.expiresAt.map { Double($0) <= Date().timeIntervalSince1970 } == true ? "Expired" : "Inactive")
                                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(key.projectName + " · " + key.id).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 200)
                } else { Text(showInactive ? "No keys found." : "No active keys.").foregroundStyle(.secondary) }
                if !usage.linked(project).isEmpty {
                    Text("Linked keys include past spending.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Connect OpenAI in General Settings.").foregroundStyle(.secondary)
            }
            if !usage.error.isEmpty { Text(usage.error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct OpenAIProjectSpending: View {
    @ObservedObject var usage: OpenAIUsageStore
    let project: Project
    let openDetails: () -> Void
    var body: some View {
        if !usage.linked(project).isEmpty {
            Button(action: openDetails) {
                if let spending = usage.spending(project) {
                    HStack(spacing: 12) {
                        cardMetric("This month", openAIMoney(spending.month))
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 22)
                        cardMetric("Total", openAIMoney(spending.total))
                    }
                } else { Text("OpenAI · " + (usage.error.isEmpty ? "Not synced" : "Needs attention")) }
            }
            .buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(usage.error.isEmpty ? Color.secondary : Color.orange)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .help(usage.historyLabel + " Open details for usage and refresh status.")
        }
    }
    private func cardMetric(_ title: String, _ amount: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            Text(amount).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(usage.error.isEmpty ? Color.primary : Color.orange)
        }
    }

}

struct OpenAIProjectUsageDetails: View {
    @ObservedObject var usage: OpenAIUsageStore
    let project: Project
    var body: some View {
        if !usage.linked(project).isEmpty {
            GeneralSettingsCard(title: "OpenAI", subtitle: "Spending & usage", icon: "chart.bar") {
                if let spending = usage.spending(project) {
                    HStack(spacing: 40) {
                        metric("This month", openAIMoney(spending.month))
                        metric("Total", openAIMoney(spending.total))
                        Spacer()
                        Button("Refresh") { Task { await usage.refresh(force: true) } }.disabled(usage.busy)
                    }
                    let ids = usage.linked(project)
                    let rows = usage.state.costs.filter { ids.contains($0.keyID) && $0.day >= openAIMonthStart(Date()) }
                    let days = Dictionary(grouping: rows, by: \.day).map { (day: $0.key, amount: $0.value.reduce(Decimal.zero) { $0 + $1.amount }) }.sorted { $0.day < $1.day }
                    if !days.isEmpty {
                        Chart(days, id: \.day) { point in
                            BarMark(x: .value("Day", Date(timeIntervalSince1970: Double(point.day)), unit: .day),
                                    y: .value("USD", NSDecimalNumber(decimal: point.amount).doubleValue))
                                .foregroundStyle(.blue.gradient)
                        }
                        .chartXScale(domain: Date(timeIntervalSince1970: Double(openAIMonthStart(Date())))...openAIUTCCalendar().dateInterval(of: .month, for: Date())!.end)
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
                        .environment(\.calendar, openAIUTCCalendar())
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .frame(height: 130).accessibilityLabel("Daily OpenAI spending this month in USD")
                    }
                    if usage.state.usageMonth == openAIMonthStart(Date()) {
                        let models = Dictionary(grouping: usage.state.usage.filter { ids.contains($0.keyID) }, by: \.model)
                        Text("Model usage this month").font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 24) {
                            let values = models.values.flatMap { $0 }
                            metric("Requests", values.reduce(0) { $0 + $1.requests }.formatted())
                            metric("Input tokens", values.reduce(0) { $0 + $1.input }.formatted())
                            metric("Output tokens", values.reduce(0) { $0 + $1.output }.formatted())
                        }
                        ForEach(models.keys.sorted(), id: \.self) { model in
                            let values = models[model] ?? []
                            LabeledContent(model, value: "\(values.reduce(0) { $0 + $1.requests }.formatted()) requests")
                        }
                    }
                    OpenAIReportingFooter(usage: usage)
                } else { Text("Not refreshed yet.").foregroundStyle(.secondary) }
                if usage.busy { ProgressView().controlSize(.small) }
                if !usage.error.isEmpty { Text(usage.error).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
        }
    }
}

struct OpenAIProjectCardFooter: View {
    @ObservedObject var store: Store
    @ObservedObject var usage: OpenAIUsageStore
    let project: Project
    var body: some View {
        if project.xcode != nil {
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                if project.xcode != nil { ProjectDeploymentActions(store: store, project: project, compact: true) }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}
