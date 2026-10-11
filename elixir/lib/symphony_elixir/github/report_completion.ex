defmodule SymphonyElixir.GitHub.ReportCompletion do
  @moduledoc "Private canonical v1 commitments; native attribution and GitHub ordering have separate clocks."

  @artifacts ~w(review.json input.json acceptance.md review-input-digest.json adjudicated-failures.json
                hosted-checks.json review.log review.timing.json delivery-plan.json delivery-source.json
                delivery-failures.json)
  @identity ~w(run_id parent_run_id work_item role model effort codex_version source_sha thread_id
               terminal_event identity_status log_digest)
  @anchor_fields ~w(id body created_at updated_at)

  @spec read(function(), map(), function()) :: {:ok, map()} | {:error, String.t()}
  def read(bytes, context, authenticate) do
    with {:ok, event, ordering, native} <- completion(bytes, context),
         {:ok, anchor_s} <- ordered(event, ordering, context, authenticate) do
      {:ok,
       Map.merge(native, %{
         completion_id: event["event_id"],
         reviewer_run_id: event["reviewer"]["run_id"],
         run_id: event["parent"]["run_id"],
         ordering_s: anchor_s
       })}
    end
  end

  @doc "Excludes only a committed, authenticated completion demonstrably before the latest reopen."
  @spec before_reopen?(function(), map(), function()) :: boolean()
  def before_reopen?(bytes, context, authenticate) do
    with %{"created_at" => at} <- context.timeline |> Enum.filter(&(&1["event"] == "reopened")) |> List.last(),
         {:ok, reopened} <- github_second(at),
         {:ok, event, ordering, _native} <- completion(bytes, context),
         {:ok, anchor_s} <- authenticated_anchor(event, ordering, context, authenticate) do
      anchor_s < reopened
    else
      _ -> false
    end
  end

  defp completion(bytes, context) do
    with {:ok, event} <- json(bytes, "review-completion.json"),
         {:ok, ordering} <- json(bytes, "closure-ordering.json"),
         true <- integrity?(event, ordering, bytes) or {:error, "completion-integrity"},
         true <- identity?(event, context) or {:error, "missing-review-identity"},
         {:ok, native} <- native_window(event, bytes) do
      {:ok, event, ordering, native}
    end
  end

  defp json(bytes, name) do
    with {:ok, value} <- bytes.(name), {:ok, %{} = object} <- Jason.decode(value) do
      {:ok, object}
    else
      _ -> {:error, "missing-completion"}
    end
  end

  defp integrity?(event, ordering, bytes) do
    event["schema_version"] == 1 and event["kind"] == "successful-review-completion" and
      ordering["schema_version"] == 1 and integer_json?(event) and
      event["event_id"] == digest(Map.delete(event, "event_id")) and ordering["event_id"] == event["event_id"] and
      artifacts?(event["artifacts"], bytes)
  end

  defp artifacts?(artifacts, bytes) when is_map(artifacts) do
    Enum.sort(Map.keys(artifacts)) == Enum.sort(@artifacts) and
      Enum.all?(artifacts, fn {name, expected} ->
        case bytes.(name) do
          {:ok, value} -> hash(value) == expected
          _ -> false
        end
      end)
  end

  defp artifacts?(_, _), do: false

  defp identity?(event, %{usage: usage} = context) do
    completion_scope?(event, context) and run_identity?(event, usage, context.number) and
      successful_reviewer?(usage, context.sha) and
      event["usage_identity_digest"] == digest(Map.new(@identity, &{&1, usage[&1]})) and
      usage["log_digest"] == event["artifacts"]["review.log"]
  end

  defp completion_scope?(event, context) do
    event["repository"] == context.repo and event["issue"] == context.number and
      event["source_sha"] == context.sha and event["base_sha"] == context.sha and
      event["scope_digest"] == digest(context.scope) and event["lifecycle_before"] == context.input_lifecycle and
      event["receipt"] == Enum.join(context.parts, "/") and event["delivery_attempt_id"] == List.last(context.parts)
  end

  defp run_identity?(event, usage, number) do
    parent = %{
      "run_id" => usage["parent_run_id"],
      "work_item" => usage["work_item"],
      "attempt_id" => usage["parent_run_id"]
    }

    reviewer = Map.new(~w(run_id thread_id model effort), &{&1, usage[&1]})

    event["parent"] == parent and event["reviewer"] == reviewer and
      Enum.all?([parent["run_id"] | Map.values(reviewer)], &(is_binary(&1) and &1 != "")) and
      parent["run_id"] != reviewer["run_id"] and parent["work_item"] == "GH-#{number}"
  end

  defp successful_reviewer?(usage, sha) do
    usage["identity_status"] == "unique" and usage["role"] == "reviewer" and
      usage["terminal_event"] == "turn.completed" and usage["source_sha"] == sha
  end

  defp native_window(event, bytes) do
    with %{
           "clock" => "producer-wall-clock",
           "ordering_authority" => false,
           "started_at_epoch_us" => started,
           "completed_at_epoch_us" => completed,
           "accepted_at_epoch_us" => accepted
         } <-
           event["native_window"],
         true <- Enum.all?([started, completed, accepted], &(is_integer(&1) and &1 > 0)),
         true <- started <= completed and completed <= accepted,
         {:ok, timing} <- json(bytes, "review.timing.json"),
         true <- timing["attempt"] == event["reviewer"]["run_id"],
         true <-
           native_time?(timing["started_at_epoch"], started) and native_time?(timing["completed_at_epoch"], completed) do
      {:ok,
       %{
         native_started_s: started / 1_000_000,
         reviewed_s: completed / 1_000_000,
         native_accepted_s: accepted / 1_000_000
       }}
    else
      _ -> {:error, "missing-native-window"}
    end
  end

  defp native_time?(time, micros), do: is_number(time) and trunc(time * 1_000_000) == micros

  defp ordered(event, ordering, context, authenticate) do
    with {:ok, anchor_s} <- authenticated_anchor(event, ordering, context, authenticate),
         true <- lifecycle_matches?(event, ordering, context) or {:error, "changed-lifecycle"},
         {:ok, closed_s} <- github_second(context.raw["closed_at"]),
         true <- anchor_s < closed_s or {:error, "ambiguous-or-late-completion"},
         true <- prior_lifecycle?(event["lifecycle_before"], anchor_s) or {:error, "ambiguous-lifecycle"} do
      {:ok, anchor_s}
    end
  end

  defp authenticated_anchor(event, ordering, context, authenticate) do
    with %{"id" => id} = saved when is_integer(id) and id > 0 <- ordering["anchor"],
         {:ok, anchor} when is_map(anchor) <- authenticate.(id),
         true <- anchor_matches?(event, saved, anchor, context) do
      github_second(anchor["created_at"])
    else
      _ -> {:error, "changed-anchor"}
    end
  end

  defp anchor_matches?(event, saved, anchor, context) do
    body = "<!-- symphony-review-completion-v1 -->\nCompletion commitment: sha256:#{event["event_id"]}"

    Map.take(anchor, @anchor_fields) == saved and anchor["body"] == body and
      anchor["created_at"] == anchor["updated_at"] and
      anchor["issue_url"] == "https://api.github.com/repos/#{context.repo}/issues/#{context.number}" and
      Enum.count(context.timeline, &(&1["event"] == "commented" and &1["body"] == body)) == 1
  end

  defp lifecycle_matches?(event, ordering, context) do
    lifecycle =
      context.timeline
      |> Enum.filter(&(&1["event"] in ["closed", "reopened"]))
      |> Enum.map(&Map.take(&1, ~w(id event created_at)))

    before = event["lifecycle_before"]
    closed = List.last(lifecycle)

    is_list(before) and ordering["lifecycle_before"] == before and
      Enum.all?(lifecycle, &valid_lifecycle?/1) and length(Enum.uniq_by(lifecycle, & &1["id"])) == length(lifecycle) and
      Enum.drop(lifecycle, -1) == before and closure_matches?(closed, ordering, context.raw)
  end

  defp closure_matches?(%{"event" => "closed", "created_at" => at}, ordering, raw) do
    raw["state"] == "closed" and raw["state_reason"] == "completed" and
      ordering["expected_state_reason"] == "completed" and raw["closed_at"] == at
  end

  defp closure_matches?(_, _, _), do: false

  defp valid_lifecycle?(%{"id" => id, "created_at" => at}) do
    is_integer(id) and id > 0 and match?({:ok, _}, github_second(at))
  end

  defp valid_lifecycle?(_), do: false

  defp prior_lifecycle?([], _anchor), do: true

  defp prior_lifecycle?(before, anchor) do
    {:ok, at} = github_second(List.last(before)["created_at"])
    at < anchor
  end

  defp github_second(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, %{microsecond: {0, 0}} = time, 0} -> {:ok, DateTime.to_unix(time)}
      _ -> {:error, "missing-github-time"}
    end
  end

  defp github_second(_), do: {:error, "missing-github-time"}

  defp integer_json?(value) when is_map(value), do: Enum.all?(value, fn {_key, item} -> integer_json?(item) end)
  defp integer_json?(value) when is_list(value), do: Enum.all?(value, &integer_json?/1)
  defp integer_json?(value), do: not is_float(value)

  defp digest(value), do: value |> sorted_json() |> Jason.encode!() |> hash()

  defp sorted_json(value) when is_map(value),
    do: Jason.OrderedObject.new(value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, sorted_json(item)} end))

  defp sorted_json(value) when is_list(value), do: Enum.map(value, &sorted_json/1)
  defp sorted_json(value), do: value
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
