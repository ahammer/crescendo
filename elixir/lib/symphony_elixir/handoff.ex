defmodule SymphonyElixir.Handoff do
  @moduledoc "Canonical final-attempt handoff contract shared by prompts and GitHub admission."

  alias SymphonyElixir.Tracker.Issue

  @spec instructions() :: String.t()
  def instructions do
    """
    ## Canonical outcome handoff

    Reuse the existing canonical issue for the unmet outcome. An unchanged blocker, new diagnostic
    evidence, unmerged PR or new issue number grants no fresh delivery budget. Keep required native
    dependency/capability edges, unique source SHAs, evidence and accepted/unaccepted dispositions
    on that owner. Retry it through the bounded blocked policy, deliver an accepted reduced slice,
    or explicitly decline the unmet outcome with a reason. Investigations remain allowed within that budget.

    Do not create or promote a ready replacement for unchanged work. After actual partial delivery
    or a newly satisfied prerequisite, grooming may authorize one successor by putting the same
    JSON record in BOTH the canonical owner's body and successor's body:
    <!-- crescendo:handoff {"owner":123,"change":"partial_delivery","evidence":456,"scope":"accepted slice and exact unmet remainder"} -->
    For partial_delivery, evidence is a merged PR explicitly closing the canonical owner. For
    prerequisite, evidence is a native blocked-by issue of the owner, completed after its closure.
    The canonical owner must be closed and cannot itself be a successor. Scope records what was
    accepted and what remains; prose edits and reusing the same proof do not renew attempts.
    Transfer required edges before disposition, preserve the original owner edge as history, and
    never treat not_planned as dependency acceptance. Leave unrelated issues, PRs and holds intact.
    Local prompt rollout belongs to the operator; this contract governs final-attempt replacements.
    """
  end

  @spec record(Issue.t()) :: map() | :invalid | nil
  def record(%Issue{kind: :issue, description: text}) when is_binary(text) do
    case Regex.scan(~r/<!--\s*crescendo:handoff\s+(.*?)\s*-->/s, text) do
      [[_, json]] -> decode(json)
      [] -> if missing_record?(text), do: :invalid
      _ -> :invalid
    end
  end

  def record(%Issue{}), do: nil

  defp missing_record?(text) do
    Regex.match?(~r/<!--\s*crescendo:handoff\b/, text) or
      Regex.match?(~r/^\s*\#+\s+[^\n]*(?:replacement of|remainder from)\s+[^\n]*#\d+/im, text)
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{"owner" => owner, "change" => change, "evidence" => evidence, "scope" => scope} = record}
      when is_integer(owner) and owner > 0 and is_integer(evidence) and evidence > 0 and
             change in ["partial_delivery", "prerequisite"] and is_binary(scope) ->
        if String.trim(scope) != "", do: record, else: :invalid

      _ ->
        :invalid
    end
  end

  @spec budget_key(map()) :: String.t()
  def budget_key(record), do: "handoff:#{record["owner"]}:#{record["change"]}:#{record["evidence"]}"
end
