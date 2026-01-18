defmodule Beamlens.TestingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  test "mock client returns queued responses in order" do
    client =
      Beamlens.Testing.mock_client([
        Puck.Response.new(content: "first"),
        Puck.Response.new(content: "second")
      ])

    result1 = Puck.call(client, "hi", Puck.Context.new())
    result2 = Puck.call(client, "hi", Puck.Context.new())

    assert match?(
             {
               {:ok, %Puck.Response{content: "first"}, %Puck.Context{}},
               {:ok, %Puck.Response{content: "second"}, %Puck.Context{}}
             },
             {result1, result2}
           )
  end
end
