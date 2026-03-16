defmodule SymphonyElixir.PiEventMapperTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.EventMapper

  test "session_started emits a compatible orchestrator update" do
    update = EventMapper.session_started("pi-session-turn-1", %{worker_pid: "1234"})

    assert update.event == :session_started
    assert update.session_id == "pi-session-turn-1"
    assert update.worker_pid == "1234"
    assert %DateTime{} = update.timestamp
  end

  test "turn_end events carry assistant usage into turn_completed updates" do
    payload = %{
      "type" => "turn_end",
      "message" => %{
        "role" => "assistant",
        "usage" => %{"input" => 12, "output" => 4, "totalTokens" => 16}
      },
      "toolResults" => []
    }

    update = EventMapper.rpc_event(payload, Jason.encode!(payload), "pi-session-turn-2", %{})

    assert update.event == :turn_completed
    assert update.session_id == "pi-session-turn-2"
    assert update.usage == %{"input" => 12, "output" => 4, "totalTokens" => 16}
    assert %DateTime{} = update.timestamp
  end

  test "non-terminal rpc events are surfaced as notifications" do
    payload = %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "SPIKE"}}

    update = EventMapper.rpc_event(payload, Jason.encode!(payload), "pi-session-turn-3", %{})

    assert update.event == :notification
    assert update.session_id == "pi-session-turn-3"
    assert update.payload == payload
    refute Map.has_key?(update, :usage)
  end
end
