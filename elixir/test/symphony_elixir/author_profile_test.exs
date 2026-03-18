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

  test "falls back to defaults when the author profile json is invalid" do
    profile_path =
      Path.join(System.tmp_dir!(), "symphony-author-profile-invalid-#{System.unique_integer([:positive])}.json")

    File.write!(profile_path, "{not-json")
    on_exit(fn -> File.rm(profile_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_author_profile_path: profile_path
    )

    profile = AuthorProfile.load()
    assert profile.comment_tone == "measured"
    assert profile.terse_by_default
    assert profile.draft_replies_first
  end

  test "normalizes blank profile fields and summarizes with measured certainty" do
    profile_path =
      Path.join(System.tmp_dir!(), "symphony-author-profile-blank-#{System.unique_integer([:positive])}.json")

    File.write!(
      profile_path,
      Jason.encode!(%{
        "commit_tone" => "   ",
        "pr_tone" => "",
        "comment_tone" => "  ",
        "certainty_language" => "measured",
        "terse_by_default" => "invalid",
        "draft_replies_first" => "invalid"
      })
    )

    on_exit(fn -> File.rm(profile_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_author_profile_path: profile_path
    )

    profile = AuthorProfile.load()
    assert profile.commit_tone == "concise"
    assert profile.pr_tone == "clear"
    assert profile.comment_tone == "measured"
    assert profile.terse_by_default
    assert profile.draft_replies_first

    long_text =
      "definitely ship this change now because it must unblock the release and " <>
        String.duplicate("trimmed text ", 20)

    summary = AuthorProfile.summarize(long_text, :comment)
    refute summary =~ "definitely "
    refute summary =~ "must "
    assert String.length(summary) <= 120
  end

  test "summarize honors non-measured certainty and commit messages truncate to 72 chars" do
    profile_path =
      Path.join(System.tmp_dir!(), "symphony-author-profile-direct-#{System.unique_integer([:positive])}.json")

    File.write!(
      profile_path,
      Jason.encode!(%{
        "commit_tone" => "descriptive",
        "pr_tone" => "clear",
        "comment_tone" => "direct",
        "certainty_language" => "direct",
        "terse_by_default" => false,
        "draft_replies_first" => false
      })
    )

    on_exit(fn -> File.rm(profile_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_author_profile_path: profile_path
    )

    summary = AuthorProfile.summarize("definitely must remain unchanged", :general)
    assert summary =~ "definitely"
    assert summary =~ "must"

    commit_message =
      AuthorProfile.commit_message(
        %{identifier: "EVT-999"},
        "This summary should be truncated because it is deliberately much longer than the git subject budget allows"
      )

    assert String.starts_with?(commit_message, "EVT-999: ")
    assert String.length(commit_message) == 72
  end
end
