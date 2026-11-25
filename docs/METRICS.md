# Metrics

`GET /metrics` serves health and cached address book counts in Prometheus text format
0.0.4. [metrics.prom](metrics.prom) is a synthetic example of every metric, type,
label, and help text; see the [format specification](https://prometheus.io/docs/instrumenting/exposition_formats/).

## Counts

Counts come from the Contacts framework alone, so collecting them never launches
Contacts and needs no Automation grant.

| Metric                     | Labels                              |
| -------------------------- | ----------------------------------- |
| `contacts_containers`      | None                                |
| `contacts_container_info`  | `container_id`, `name`, `type`      |
| `contacts_contacts`        | `container_id`, `contact_type`      |
| `contacts_contacts_with`   | `container_id`, `key`               |
| `contacts_labeled_values`  | `container_id`, `key`, `label_kind` |
| `contacts_groups`          | `container_id`                      |
| `contacts_group_info`      | `container_id`, `group_id`, `name`  |
| `contacts_group_members`   | `group_id`                          |
| `contacts_linked_contacts` | None                                |
| `contacts_me_contact`      | None                                |

`contact_type` is `person` or `organization`; the two partition every card.
`contacts_contacts_with` counts cards that have a value for `key`: `image_data`,
`phone_numbers`, `email_addresses`, `postal_addresses`, `url_addresses`, `birthday`,
or `organization_name`. `contacts_labeled_values` counts entries of the phone, email,
postal address, and URL lists by `label_kind`: `builtin`, `custom`, or `none`. Every
label combination is emitted, including zeros.

Labels carry identifiers and the names of containers and groups. Nothing from a card
is a label: no names, addresses, or custom label text.

## Refresh

Counts are collected at startup and then `CONTACTS_METRICS_INTERVAL_SECONDS` after
each collection; a scrape never triggers one.
`contacts_observation_timestamp_seconds` says when they were read. After a failed
collection the counts are withdrawn, `contacts_store_up` reports 0, and the collector
retries after a minute, doubling toward the interval.

## Health

| Metric                                      | Meaning                                                            |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `process_start_time_seconds`                | A change is a restart.                                             |
| `contacts_http_requests_total`              | Requests by `route` and status `code`.                             |
| `contacts_main_actor_heartbeat_age_seconds` | Seconds since the main actor answered; the process exits past 120. |
| `contacts_authorization_pending`            | 1 while the startup access request waits for an answer.            |
| `contacts_access_granted`                   | 1 when macOS grants access to Contacts.                            |
| `contacts_store_up`                         | 1 when the last collection succeeded.                              |

These are computed on every scrape and served even when the counts are not.
