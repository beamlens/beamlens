defmodule Mix.Tasks.Beamlens.InstallTest do
  use ExUnit.Case
  import Igniter.Test

  alias Mix.Tasks.Beamlens.Install

  describe "default installation (no provider)" do
    test "creates Application module with bare Beamlens child" do
      test_project()
      |> Install.igniter()
      |> assert_creates("lib/test/application.ex")
    end

    test "uses bare Beamlens without client_registry" do
      igniter =
        test_project()
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ "Beamlens"
      refute content =~ "client_registry:"
    end

    test "updates mix.exs with Application module reference" do
      test_project()
      |> Install.igniter()
      |> assert_has_patch("mix.exs", """
      + |      mod: {Test.Application, []}
      """)
    end

    test "adds Beamlens to existing Application children list" do
      test_project(files: %{"lib/test/application.ex" => existing_application()})
      |> Install.igniter()
      |> assert_has_patch("lib/test/application.ex", """
      + |      Beamlens
      """)
    end

    test "preserves existing children when adding Beamlens" do
      igniter =
        test_project(files: %{"lib/test/application.ex" => existing_application()})
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ "SomeOtherChild"
      assert content =~ "Beamlens"
    end

    test "adds Beamlens after existing children" do
      igniter =
        test_project(files: %{"lib/test/application.ex" => existing_application()})
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")

      {some_other_pos, _} = :binary.match(content, "SomeOtherChild")
      {beamlens_pos, _} = :binary.match(content, "Beamlens")

      assert beamlens_pos > some_other_pos,
             "Beamlens should be added after existing children"
    end

    test "model option without provider is ignored" do
      igniter =
        test_project()
        |> set_options(model: "custom-model")
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ "Beamlens"
      refute content =~ "client_registry:"
      refute content =~ "custom-model"
    end
  end

  describe "idempotency" do
    test "does not duplicate when bare Beamlens already present" do
      test_project(files: %{"lib/test/application.ex" => application_with_bare_beamlens()})
      |> Install.igniter()
      |> assert_unchanged("lib/test/application.ex")
    end

    test "does not duplicate when Beamlens with client_registry already present" do
      test_project(files: %{"lib/test/application.ex" => application_with_beamlens()})
      |> Install.igniter()
      |> assert_unchanged("lib/test/application.ex")
    end
  end

  describe "provider configuration" do
    test "explicit --provider anthropic generates client_registry" do
      config = Map.fetch!(Install.providers(), "anthropic")

      igniter =
        test_project()
        |> set_options(provider: "anthropic")
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ "client_registry:"
      assert content =~ ~s("#{config.name}")
      assert content =~ ~s("#{config.provider}")
      assert content =~ config.default_model
    end

    for {provider_key, _config} <- Install.providers() do
      @tag provider: provider_key
      test "configures #{provider_key} provider with correct defaults" do
        provider_key = unquote(provider_key)
        config = Map.fetch!(Install.providers(), provider_key)

        igniter =
          test_project()
          |> set_options(provider: provider_key)
          |> Install.igniter()

        content = get_file_content(igniter, "lib/test/application.ex")
        assert content =~ ~s("#{config.name}")
        assert content =~ ~s("#{config.provider}")
        assert content =~ config.default_model
      end
    end

    test "ollama includes base_url configuration" do
      config = Map.fetch!(Install.providers(), "ollama")

      igniter =
        test_project()
        |> set_options(provider: "ollama")
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ config.base_url
    end

    test "custom model overrides provider default" do
      igniter =
        test_project()
        |> set_options(provider: "openai", model: "gpt-5.2")
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ "gpt-5.2"
      refute content =~ "gpt-5-mini"
    end

    test "anthropic with custom model uses specified model" do
      igniter =
        test_project()
        |> set_options(provider: "anthropic", model: "claude-sonnet-4-20250514")
        |> Install.igniter()

      content = get_file_content(igniter, "lib/test/application.ex")
      assert content =~ "claude-sonnet-4-20250514"
      refute content =~ "claude-haiku-4-5-20251001"
    end
  end

  describe "environment variable notices" do
    for {provider_key, config} <- Install.providers(), config.env_var != nil do
      @tag provider: provider_key
      test "#{provider_key} adds notice for #{config.env_var}" do
        provider_key = unquote(provider_key)
        config = Map.fetch!(Install.providers(), provider_key)

        test_project()
        |> set_options(provider: provider_key)
        |> Install.igniter()
        |> assert_has_notice(&String.contains?(&1, config.env_var))
      end
    end
  end

  describe "local provider notices" do
    test "ollama adds notice about running server" do
      config = Map.fetch!(Install.providers(), "ollama")

      test_project()
      |> set_options(provider: "ollama")
      |> Install.igniter()
      |> assert_has_notice(&String.contains?(&1, config.base_url))
    end
  end

  describe "invalid provider" do
    test "raises KeyError for unknown provider" do
      assert_raise KeyError, fn ->
        test_project()
        |> set_options(provider: "unknown")
        |> Install.igniter()
      end
    end
  end

  describe "cloud provider configuration notices" do
    test "azure-openai adds notice about resource configuration" do
      test_project()
      |> set_options(provider: "azure-openai")
      |> Install.igniter()
      |> assert_has_notice(&String.contains?(&1, "resource_name"))
      |> assert_has_notice(&String.contains?(&1, "deployment_id"))
    end

    test "vertex-ai adds notice about project configuration" do
      test_project()
      |> set_options(provider: "vertex-ai")
      |> Install.igniter()
      |> assert_has_notice(&String.contains?(&1, "project_id"))
      |> assert_has_notice(&String.contains?(&1, "location"))
    end

    test "aws-bedrock adds notice about region configuration" do
      test_project()
      |> set_options(provider: "aws-bedrock")
      |> Install.igniter()
      |> assert_has_notice(&String.contains?(&1, "region"))
    end
  end

  defp set_options(igniter, options) do
    args = %Igniter.Mix.Task.Args{
      positional: %{},
      options: options,
      argv: [],
      argv_flags: []
    }

    %{igniter | args: args}
  end

  defp get_file_content(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp existing_application do
    """
    defmodule Test.Application do
      use Application

      def start(_type, _args) do
        children = [
          {SomeOtherChild, []}
        ]

        opts = [strategy: :one_for_one, name: Test.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end

  defp application_with_bare_beamlens do
    """
    defmodule Test.Application do
      use Application

      def start(_type, _args) do
        children = [
          {OtherChild, []},
          Beamlens
        ]

        opts = [strategy: :one_for_one, name: Test.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end

  defp application_with_beamlens do
    """
    defmodule Test.Application do
      use Application

      def start(_type, _args) do
        children = [
          {OtherChild, []},
          {Beamlens, [client_registry: %{primary: "Anthropic", clients: []}]}
        ]

        opts = [strategy: :one_for_one, name: Test.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end
end
