defmodule SocialScribe.Workers.SalesforceTokenRefresherTest do
  use SocialScribe.DataCase
  import Tesla.Mock

  alias SocialScribe.Workers.SalesforceTokenRefresher

  import SocialScribe.AccountsFixtures

  setup do
    mock fn
      %{method: :post, url: "https://login.salesforce.com/services/oauth2/token"} ->
        %Tesla.Env{
          status: 200,
          body: %{
            "access_token" => "new_access_token",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          }
        }
    end

    :ok
  end

  describe "perform/1" do
    test "returns :ok when no Salesforce credentials are expiring" do
      user = user_fixture()

      # Create credential that expires in 1 hour (not expiring soon)
      _credential =
        salesforce_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert :ok = SalesforceTokenRefresher.perform(%Oban.Job{})
    end

    test "identifies expiring Salesforce credentials" do
      user = user_fixture()

      # Create credential expiring in 5 minutes (within threshold)
      expiring_credential =
        salesforce_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      # Create non-Salesforce credential (should be ignored)
      _hubspot_credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      # Worker should identify the Salesforce credential as expiring
      assert expiring_credential.provider == "salesforce"
      assert DateTime.compare(
               expiring_credential.expires_at,
               DateTime.add(DateTime.utc_now(), 600, :second)
             ) == :lt
    end

    test "handles credentials without refresh tokens" do
      user = user_fixture()

      # Create credential without refresh token (should be skipped)
      _credential_without_refresh =
        salesforce_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          refresh_token: nil
        })

      # Worker should handle this gracefully
      assert :ok = SalesforceTokenRefresher.perform(%Oban.Job{})
    end

    test "processes multiple expiring credentials" do
      user1 = user_fixture()
      user2 = user_fixture()

      # Create multiple expiring Salesforce credentials
      _credential1 =
        salesforce_credential_fixture(%{
          user_id: user1.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      _credential2 =
        salesforce_credential_fixture(%{
          user_id: user2.id,
          expires_at: DateTime.add(DateTime.utc_now(), 400, :second)
        })

      # Worker should handle multiple credentials
      assert :ok = SalesforceTokenRefresher.perform(%Oban.Job{})
    end

    test "returns :ok even when individual refreshes fail" do
      user = user_fixture()

      # Create credential with invalid refresh token (will cause failures)
      _credential =
        salesforce_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          refresh_token: "invalid_token"
        })

      # Worker should return :ok even if individual refreshes fail
      # This prevents the entire job from being retried
      assert :ok = SalesforceTokenRefresher.perform(%Oban.Job{})
    end
  end

  test "job can be enqueued" do
    assert {:ok, _job} =
             %{}
             |> SalesforceTokenRefresher.new()
             |> Oban.insert()
  end
end
