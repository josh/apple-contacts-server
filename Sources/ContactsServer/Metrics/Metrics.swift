import Foundation

import struct os.OSAllocatedUnfairLock

private let processStart = Date()
private struct RequestKey: Hashable { let route: String, code: Int }
private let requestCounts = OSAllocatedUnfairLock<[RequestKey: Int]>(initialState: [:])

func recordRequest(route: String, code: Int) {
  requestCounts.withLock { $0[RequestKey(route: route, code: code), default: 0] += 1 }
}

// Prometheus metric types the exposition uses.
enum MetricType: String { case counter, gauge }
private func familyHeader(_ name: String, _ type: MetricType, _ help: String) -> [String] {
  ["# HELP \(name) \(help)", "# TYPE \(name) \(type.rawValue)"]
}

// Served even when the store gauges are not: a failed read must not blank the request
// and liveness series that explain it.
func runtimeMetrics(storeUp: Bool, authorizing: Bool) -> String {
  var lines: [String] = []
  lines += familyHeader(
    "process_start_time_seconds", .gauge,
    "Start time of the process since the Unix epoch; a change is a restart.")
  lines.append("process_start_time_seconds \(Int(processStart.timeIntervalSince1970))")
  lines += familyHeader(
    "contacts_http_requests_total", .counter, "HTTP requests answered, by route and status code.")
  let counts = requestCounts.withLock { $0 }
  for (key, count) in counts.sorted(by: {
    ($0.key.route, $0.key.code) < ($1.key.route, $1.key.code)
  }) {
    lines.append(
      "contacts_http_requests_total{route=\"\(metricEscape(key.route))\",code=\"\(key.code)\"} \(count)"
    )
  }
  lines += familyHeader(
    "contacts_main_actor_heartbeat_age_seconds", .gauge,
    "Seconds since the main actor last ran a watchdog heartbeat; the process exits past \(mainActorWatchdogLimit.components.seconds)."
  )
  lines.append(
    "contacts_main_actor_heartbeat_age_seconds \(mainActorHeartbeatAge() / .seconds(1))")
  lines += familyHeader(
    "contacts_authorization_pending", .gauge,
    "1 while the startup Contacts access request has not been answered; /graphql and /mcp answer NOT_AUTHORIZED meanwhile."
  )
  lines.append("contacts_authorization_pending \(authorizing ? 1 : 0)")
  lines += familyHeader(
    "contacts_access_granted", .gauge,
    "1 when macOS grants this process access to Contacts; without it /graphql and /mcp answer NOT_AUTHORIZED."
  )
  lines.append("contacts_access_granted \(hasAccess ? 1 : 0)")
  lines += familyHeader(
    "contacts_store_up", .gauge,
    "1 when the last background read of the contact store succeeded and its gauges follow.")
  lines.append("contacts_store_up \(storeUp ? 1 : 0)")
  return lines.joined(separator: "\n") + "\n"
}

func metricEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
actor MetricsCollector {
  private(set) var exposition: String?

  func run(interval: Duration) async {
    var failed = false
    var delay = interval
    while !Task.isCancelled {
      do {
        exposition = try await collectMetrics()
        if failed { serverLogger.info("Metrics collection recovered") }
        failed = false
        delay = interval
      } catch {
        logFailure("Metrics collection failed", error: error)
        exposition = nil
        // Retry after a minute, doubling toward the interval so a lasting failure stays quiet.
        delay = failed ? min(delay * 2, interval) : min(.seconds(60), interval)
        failed = true
      }
      do { try await Task.sleep(for: delay) } catch { return }
    }
  }
}

// Which labelled entries a gauge counts, and how their labels divide.
private enum LabelKind: String, CaseIterable { case builtin, custom, none }
private func labelKind(_ label: String?) -> LabelKind {
  guard let label, !label.isEmpty else { return .none }
  return isBuiltInLabel(label) ? .builtin : .custom
}
private func label(_ key: ContactKey) -> String { key.rawValue.lowercased() }
// Parts of a card worth watching for coverage across the address book.
private let coverageKeys: [ContactKey] = [
  .imageData, .phoneNumbers, .emailAddresses, .postalAddresses, .urlAddresses, .birthday,
  .organizationName,
]
private let labeledKeys: [(ContactKey, (ContactRecord) -> [String?])] = [
  (.phoneNumbers, { $0.phoneNumbers.map(\.label) }),
  (.emailAddresses, { $0.emailAddresses.map(\.label) }),
  (.postalAddresses, { $0.postalAddresses.map(\.label) }),
  (.urlAddresses, { $0.urlAddresses.map(\.label) }),
]

// Store gauges come from the Contacts framework alone, so collecting them never launches
// Contacts. Labels carry identifiers and the names of containers and groups, never what
// is on a card. Every label combination is emitted, zeros included, so a series never
// disappears.
func collectMetrics() async throws -> String {
  let now = Date()
  let data = try await readContactsData()
  var lines: [String] = []
  func family(_ name: String, _ help: String) { lines += familyHeader(name, .gauge, help) }
  family(
    "contacts_observation_timestamp_seconds",
    "When the store gauges were read, since the Unix epoch.")
  lines.append("contacts_observation_timestamp_seconds \(Int(now.timeIntervalSince1970))")

  family("contacts_containers", "Containers the store reports.")
  lines.append("contacts_containers \(data.containers.count)")
  family(
    "contacts_container_info",
    "One series per container, carrying its name and type; the value is always 1.")
  for container in data.containers {
    lines.append(
      "contacts_container_info{container_id=\"\(metricEscape(container.identifier))\",name=\"\(metricEscape(container.name))\",type=\"\(container.type.rawValue.lowercased())\"} 1"
    )
  }
  let byContainer = Dictionary(grouping: data.contacts, by: { $0.containerIdentifier ?? "" })
  family("contacts_contacts", "Stored cards, by container and contact type.")
  for container in data.containers {
    let cards = byContainer[container.identifier] ?? []
    for type in ContactType.allCases {
      lines.append(
        "contacts_contacts{container_id=\"\(metricEscape(container.identifier))\",contact_type=\"\(type.rawValue.lowercased())\"} \(cards.count { $0.contactType == type })"
      )
    }
  }
  family("contacts_contacts_with", "Stored cards that have a value for the key, by container.")
  for container in data.containers {
    let cards = byContainer[container.identifier] ?? []
    for key in coverageKeys {
      lines.append(
        "contacts_contacts_with{container_id=\"\(metricEscape(container.identifier))\",key=\"\(label(key))\"} \(cards.count { $0.has(key) })"
      )
    }
  }
  family(
    "contacts_labeled_values",
    "Labelled entries on stored cards, by container, key, and whether the label is built in, custom, or absent."
  )
  for container in data.containers {
    let cards = byContainer[container.identifier] ?? []
    for (key, labels) in labeledKeys {
      let kinds = cards.flatMap(labels).map(labelKind)
      for kind in LabelKind.allCases {
        lines.append(
          "contacts_labeled_values{container_id=\"\(metricEscape(container.identifier))\",key=\"\(label(key))\",label_kind=\"\(kind.rawValue)\"} \(kinds.count { $0 == kind })"
        )
      }
    }
  }

  family("contacts_groups", "Groups, by container.")
  for container in data.containers {
    lines.append(
      "contacts_groups{container_id=\"\(metricEscape(container.identifier))\"} \(container.groupCount)"
    )
  }
  family("contacts_group_info", "One series per group, carrying its name; the value is always 1.")
  for group in data.groups {
    lines.append(
      "contacts_group_info{container_id=\"\(metricEscape(group.containerIdentifier))\",group_id=\"\(metricEscape(group.identifier))\",name=\"\(metricEscape(group.name))\"} 1"
    )
  }
  family("contacts_group_members", "Stored cards in each group.")
  for group in data.groups {
    lines.append(
      "contacts_group_members{group_id=\"\(metricEscape(group.identifier))\"} \(group.memberCount)"
    )
  }
  family(
    "contacts_linked_contacts", "Stored cards Contacts shows together with another card.")
  lines.append(
    "contacts_linked_contacts \(data.contacts.count { !$0.linkedContactIdentifiers.isEmpty })")
  family("contacts_me_contact", "1 when the store has a card marked as the user's own.")
  lines.append("contacts_me_contact \(data.meContactIdentifier == nil ? 0 : 1)")
  return lines.joined(separator: "\n") + "\n"
}
