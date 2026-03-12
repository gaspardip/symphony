defmodule SymphonyElixir.CredentialRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CredentialRegistry

  test "allows operations when the registry is not configured in private autopilot mode" do
    assert :ok = CredentialRegistry.allow?("github", "pr_write")
  end

  test "blocks write-like operations when the registry is not configured in contractor mode" do
    assert {:error, {:credential_scope_forbidden, "github", "pr_write"}} =
             CredentialRegistry.allow?("github", "pr_write", policy_pack: :client_safe_pr_active)

    assert {:error, {:credential_scope_forbidden, "tracker", "write"}} =
             CredentialRegistry.allow?("tracker", "write", policy_pack: :client_safe_shadow)
  end

  test "blocks company-scoped forbidden operations" do
    registry_path =
      Path.join(System.tmp_dir!(), "symphony-credential-registry-#{System.unique_integer([:positive])}.json")

    File.write!(
      registry_path,
      Jason.encode!(%{
        "companies" => %{
          "Client A" => %{
            "providers" => %{
              "github" => %{
                "forbidden_operations" => ["merge"]
              }
            }
          }
        }
      })
    )

    on_exit(fn -> File.rm(registry_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_name: "Client A",
      company_credential_registry_path: registry_path
    )

    assert {:error, {:credential_scope_forbidden, "github", "merge"}} =
             CredentialRegistry.allow?("github", "merge")

    assert :ok = CredentialRegistry.allow?("github", "pr_write")
  end

  test "repo-specific rules override company defaults" do
    registry_path =
      Path.join(System.tmp_dir!(), "symphony-credential-registry-#{System.unique_integer([:positive])}.json")

    File.write!(
      registry_path,
      Jason.encode!(%{
        "companies" => %{
          "Client A" => %{
            "providers" => %{
              "github" => %{"forbidden_operations" => ["merge"]}
            }
          }
        },
        "repos" => %{
          "git@github.com:gaspardip/events.git" => %{
            "providers" => %{
              "github" => %{"allowed_operations" => ["merge"]}
            }
          }
        }
      })
    )

    on_exit(fn -> File.rm(registry_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_name: "Client A",
      company_repo_url: "git@github.com:gaspardip/events.git",
      company_credential_registry_path: registry_path
    )

    assert :ok = CredentialRegistry.allow?("github", "merge")
  end
end
