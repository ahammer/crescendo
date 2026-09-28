defmodule SymphonyElixir.GitHub.ETagCacheTest do
  use ExUnit.Case

  alias SymphonyElixir.GitHub.ETagCache

  test "an unchanged resource answers from memory, and only successes with an ETag are remembered" do
    token = "token-#{System.unique_integer()}"
    key = ETagCache.key("https://api.github.com/repos/a/b/issues", %{"page" => 1, "state" => "open"}, token)
    # The query's order does not matter, and the token is never stored.
    assert key == ETagCache.key("https://api.github.com/repos/a/b/issues", [{"state", "open"}, {"page", 1}], token)
    refute token in Tuple.to_list(key)
    assert ETagCache.headers(key) == []

    assert %{status: 200, body: [1]} = ETagCache.resolve(key, %{status: 200, headers: %{"etag" => [~s(W/"v1")]}, body: [1]})
    assert ETagCache.headers(key) == [{"If-None-Match", ~s(W/"v1")}]
    assert ETagCache.resolve(key, %{status: 304, headers: %{}, body: ""}) == %{status: 200, body: [1]}

    # No ETag, a failure, or a 304 nobody remembers pass through untouched.
    other = ETagCache.key("https://api.github.com/other", nil, "t")
    assert ETagCache.resolve(other, %{status: 200, headers: %{}, body: :fresh}) == %{status: 200, body: :fresh}
    assert ETagCache.headers(other) == []
    assert ETagCache.resolve(other, %{status: 304, headers: %{}, body: ""}) == %{status: 304, body: ""}
    assert ETagCache.resolve(key, %{status: 502, headers: %{"etag" => ["x"]}, body: "bad"}) == %{status: 502, body: "bad"}
  end

  test "without its table (a command run) requests simply go unconditional" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ETagCache)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, ETagCache) end)

    key = ETagCache.key("https://api.github.com/x", %{}, "t")
    assert ETagCache.resolve(key, %{status: 200, headers: %{"etag" => ["e"]}, body: 1}) == %{status: 200, body: 1}
    assert ETagCache.headers(key) == []
  end

  test "a full table starts over" do
    table = :symphony_github_etags
    for n <- 1..20_000, do: :ets.insert(table, {{"u#{n}", [], 0}, "e", n})
    key = ETagCache.key("https://api.github.com/new", %{}, "t")
    ETagCache.resolve(key, %{status: 200, headers: %{"etag" => ["e2"]}, body: :new})
    assert :ets.info(table, :size) == 1
    assert ETagCache.headers(key) == [{"If-None-Match", "e2"}]
  end
end
