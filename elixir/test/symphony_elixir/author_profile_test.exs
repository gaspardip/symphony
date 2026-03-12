defmodule SymphonyElixir.AuthorProfileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AuthorProfile

  test "loads a local author profile and uses it for commit messages" do
    profile_path =
      Path.join(System.tmp_dir!(), "symphony-author-profile-#{System.unique_integer([:positive])}.json")

    File.write!(
      profile_path,
      Jason.encode!(%{
        "commit_tone" => "descriptive",
        "pr_tone" => "clear",
        "comment_tone" => "measured",
        "certainty_language" => "measured",
        "terse_by_default" => true,
        "draft_replies_first" => true
      })
    )

    on_exit(fn -> File.rm(profile_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_author_profile_path: profile_path
    )

    profile = AuthorProfile.load()
    assert profile.commit_tone == "descriptive"
    assert profile.draft_replies_first

    assert AuthorProfile.commit_message(%{identifier: "EVT-123"}, "Definitely fix onboarding persistence now") ==
             "EVT-123: Definitely fix onboarding persistence now"
  end

  test "falls back to the default author profile when the file is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      company_author_profile_path: Path.join(System.tmp_dir!(), "missing-author-profile.json")
    )

    profile = AuthorProfile.load()
    assert profile.commit_tone == "concise"
    assert profile.certainty_language == "measured"
  end
end
