defmodule SymphonyElixir.VerifierResultTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.VerifierResult

  test "normalize accepts string and atom keys and serializes back to a map" do
    assert {:ok, result} =
             VerifierResult.normalize(%{
               "verdict" => "unsafe-to-merge",
               "risky_areas" => ["Data loss"],
               summary: "High risk",
               acceptance_gaps: ["Gap", ""],
               evidence: ["Smoke failed"],
               raw_output: " raw output "
             })

    assert result.verdict == :unsafe_to_merge
    assert result.summary == "High risk"
    assert result.acceptance_gaps == ["Gap"]
    assert result.risky_areas == ["Data loss"]
    assert result.evidence == ["Smoke failed"]
    assert result.raw_output == "raw output"

    assert VerifierResult.to_map(result) == %{
             verdict: "unsafe_to_merge",
             summary: "High risk",
             acceptance_gaps: ["Gap"],
             risky_areas: ["Data loss"],
             evidence: ["Smoke failed"],
             raw_output: "raw output"
           }
  end

  test "normalize rejects missing or invalid verifier payloads" do
    assert VerifierResult.normalize(nil) == {:error, :invalid_verifier_result}
    assert VerifierResult.normalize(%{}) == {:error, {:missing_keys, [:verdict, :summary, :acceptance_gaps, :risky_areas, :evidence, :raw_output]}}
    assert VerifierResult.normalize(%{verdict: "bad", summary: "no", acceptance_gaps: [], risky_areas: [], evidence: [], raw_output: ""}) == {:error, :invalid_verdict}
    assert VerifierResult.normalize(%{verdict: "pass", summary: " ", acceptance_gaps: [], risky_areas: [], evidence: [], raw_output: ""}) == {:error, :empty_summary}
    assert VerifierResult.normalize(%{verdict: "pass", summary: "ok", acceptance_gaps: "bad", risky_areas: [], evidence: [], raw_output: ""}) == {:error, {:invalid_string_list, :acceptance_gaps}}
    assert VerifierResult.normalize(%{verdict: "pass", summary: "ok", acceptance_gaps: [], risky_areas: [], evidence: [], raw_output: 123}) == {:error, :invalid_raw_output}
  end
end
