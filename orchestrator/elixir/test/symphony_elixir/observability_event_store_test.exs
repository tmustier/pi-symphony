defmodule SymphonyElixir.ObservabilityEventStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Observability.{EventStore, PhaseTransition}

  setup do
    EventStore.clear()
    :ok
  end

  test "event store bounds and sanitizes worker payloads" do
    {:ok, pid} = EventStore.start_link(name: Module.concat(__MODULE__, :BoundedStore), max_global_events: 2, max_events_per_issue: 10)

    huge = String.duplicate("x", 10_000)

    assert {:ok, _event1} =
             EventStore.append(
               %{
                 issue_id: "issue-1",
                 issue_identifier: "MT-1",
                 type: "worker",
                 name: "notification",
                 summary: huge,
                 payload: %{raw: huge, nested: [%{message: huge}]}
               },
               pid
             )

    assert {:ok, _event2} = EventStore.append(%{issue_identifier: "MT-1", type: "worker", name: "heartbeat"}, pid)
    assert {:ok, _event3} = EventStore.append(%{issue_identifier: "MT-1", type: "phase", name: "phase.changed"}, pid)

    page = EventStore.list_for_issue("MT-1", [], pid)

    assert Enum.map(page.events, & &1.name) == ["heartbeat", "phase.changed"]
    assert Enum.all?(page.events, &(byte_size(Jason.encode!(&1.payload)) <= 4_096))
  end

  test "worker update payloads store only safe whitelisted fields" do
    {:ok, pid} = EventStore.start_link(name: Module.concat(__MODULE__, :WorkerWhitelistStore))

    secret = "super-secret-token"

    assert {:ok, event} =
             EventStore.append_worker_update(
               "issue-safe",
               "MT-SAFE",
               %{
                 event: :notification,
                 session_id: "session-safe",
                 message: "tool update",
                 raw: secret,
                 payload: %{
                   "type" => "message_update",
                   "assistantMessageEvent" => %{"type" => "text_delta", "delta" => secret},
                   "api_key" => secret
                 },
                 usage: %{"input" => 1, "output" => 2, "totalTokens" => 3, "secret" => secret}
               },
               %{session_id: "session-safe"},
               pid
             )

    assert event.redacted? == true

    assert event.summary == "notification: message_update: text_delta"

    assert event.payload == %{
             "event" => "notification",
             "payload_event_type" => "text_delta",
             "payload_type" => "message_update",
             "session_id" => "session-safe",
             "usage" => %{"input" => 1, "output" => 2, "totalTokens" => 3}
           }

    encoded_event = Jason.encode!(event)
    refute encoded_event =~ secret
  end

  test "event store bounds top-level event fields" do
    {:ok, pid} = EventStore.start_link(name: Module.concat(__MODULE__, :TopLevelBoundsStore))
    huge = String.duplicate("event-name", 1_000)

    assert {:ok, event} =
             EventStore.append(
               %{
                 issue_identifier: "MT-BOUNDS",
                 type: huge,
                 name: huge,
                 source: huge,
                 severity: huge,
                 payload: %{}
               },
               pid
             )

    assert byte_size(event.type) <= 83
    assert byte_size(event.name) <= 163
    assert byte_size(event.source) <= 83
    assert byte_size(event.severity) <= 43
  end

  test "event store supports cursor and type filtering" do
    {:ok, pid} = EventStore.start_link(name: Module.concat(__MODULE__, :CursorStore))

    {:ok, first} = EventStore.append(%{issue_identifier: "MT-2", type: "worker", name: "one"}, pid)
    {:ok, _second} = EventStore.append(%{issue_identifier: "MT-2", type: "phase", name: "two"}, pid)
    {:ok, _third} = EventStore.append(%{issue_identifier: "MT-2", type: "worker", name: "three"}, pid)

    page = EventStore.list_for_issue("MT-2", [cursor: first.id, type: "worker", limit: 1], pid)

    assert [%{name: "three"}] = page.events
    assert page.page_info.has_next_page == false
  end

  test "phase transition builder records tracked phase and waiting/action changes" do
    previous = %{
      "issue-1" => %{
        issue_id: "issue-1",
        issue_identifier: "MT-3",
        state: "In Progress",
        phase: "implementing",
        waiting_reason: nil,
        next_intended_action: "continue_worker",
        dispatch_allowed: false,
        passive_phase: false,
        workpad: %{comment_id: "comment-1"}
      }
    }

    current = %{
      "issue-1" => %{
        issue_id: "issue-1",
        issue_identifier: "MT-3",
        state: "In Review",
        phase: "waiting_for_checks",
        waiting_reason: "checks_pending",
        next_intended_action: "poll_on_next_cycle",
        dispatch_allowed: false,
        passive_phase: true,
        workpad: %{comment_id: "comment-1"}
      }
    }

    assert [transition] = PhaseTransition.transitions_from_tracked_update(previous, current, source: "test")
    assert transition.from == "implementing"
    assert transition.to == "waiting_for_checks"
    assert transition.tracker_state_from == "In Progress"
    assert transition.tracker_state_to == "In Review"
    assert transition.waiting_reason == "checks_pending"
    assert transition.next_intended_action == "poll_on_next_cycle"
    assert transition.source == "test"
  end

  test "orchestrator worker updates append to event store without losing latest-entry behavior" do
    issue = %Issue{
      id: "issue-worker-update",
      identifier: "MT-WORKER",
      title: "Worker update",
      description: "Record event",
      state: "In Progress",
      url: "https://example.test/MT-WORKER",
      labels: ["symphony"]
    }

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          issue: issue,
          identifier: issue.identifier,
          session_id: "session-1",
          started_at: DateTime.utc_now(),
          worker_input_tokens: 0,
          worker_output_tokens: 0,
          worker_total_tokens: 0
        }
      },
      worker_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    secret_message = "hello-secret-token"

    assert {:noreply, updated_state} =
             Orchestrator.handle_info(
               {:worker_update, issue.id, %{event: :notification, timestamp: DateTime.utc_now(), message: secret_message, raw: String.duplicate("x", 10_000)}},
               state
             )

    page = EventStore.list_for_issue("MT-WORKER", type: "worker")
    assert [%{name: "notification", summary: "notification"} = event] = page.events
    refute Jason.encode!(event) =~ secret_message

    assert %{last_worker_event: :notification, last_worker_message: _message} = updated_state.running[issue.id]
  end
end
