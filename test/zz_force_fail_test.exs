defmodule Letflow.ZzForceFailTest do
  # THROWAWAY proof for sharding PR2 (#2374): this test must fail exactly one shard
  # and turn the aggregator red. Never merged.
  use ExUnit.Case, async: true

  test "zz force fail (proof 2 of the sharded gate)" do
    assert false
  end
end
