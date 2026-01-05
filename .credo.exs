%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        # Library consumers configure their own Logger metadata
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false}
      ]
    }
  ]
}
