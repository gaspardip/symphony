import Config

service_name = System.get_env("OTEL_SERVICE_NAME") || "symphony"
service_namespace = System.get_env("OTEL_SERVICE_NAMESPACE") || "symphony"
deployment_environment = System.get_env("OTEL_DEPLOYMENT_ENVIRONMENT") || config_env() |> Atom.to_string()
otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

config :opentelemetry,
  resource: [
    service: [
      name: service_name,
      namespace: service_namespace
    ],
    deployment: [
      environment: deployment_environment
    ]
  ]

if is_binary(otlp_endpoint) and String.trim(otlp_endpoint) != "" do
  config :opentelemetry,
    processors: [
      {:otel_batch_processor,
       %{
         exporter: {:opentelemetry_exporter, %{}}
       }}
    ]

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    endpoints: [String.trim(otlp_endpoint)]
else
  config :opentelemetry, processors: []
end
