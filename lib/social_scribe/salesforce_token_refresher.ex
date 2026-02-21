defmodule SocialScribe.SalesforceTokenRefresher do
  @moduledoc """
  Refreshes Salesforce OAuth tokens.
  """

  require Logger
  alias SocialScribe.Accounts

  def client do
    Tesla.client([
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Timeout, timeout: 30_000},
      Tesla.Middleware.Logger
    ])
  end

  @doc """
  Refreshes a Salesforce access token using the refresh token.
  Returns {:ok, response_body} with new access_token and expires_in.
  """
  def refresh_token(refresh_token, _instance_url \\ nil) do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    # Salesforce token refresh always uses login.salesforce.com
    token_url = "https://login.salesforce.com/services/oauth2/token"

    body = %{
      grant_type: "refresh_token",
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token
    }

    Logger.info("Refreshing Salesforce token using login.salesforce.com")

    case Tesla.post(client(), token_url, body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        Logger.info("Salesforce token refresh successful")
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("Salesforce token refresh failed: #{status} - #{inspect(error_body)}")
        {:error, {status, error_body}}

      {:error, reason} ->
        Logger.error("Salesforce token refresh request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refreshes the token for a Salesforce credential and updates it in the database.
  """
  def refresh_credential(credential) do
    Logger.info("Refreshing credential for user: #{credential.user_id}")

    case refresh_token(credential.refresh_token) do
      {:ok, response} ->
        attrs = %{
          token: response["access_token"],
          refresh_token: response["refresh_token"] || credential.refresh_token,
          expires_at: DateTime.add(DateTime.utc_now(), response["expires_in"] || 3600, :second)
        }

        case Accounts.update_user_credential(credential, attrs) do
          {:ok, updated_credential} ->
            Logger.info("Credential refreshed successfully for user: #{credential.user_id}")
            {:ok, updated_credential}

          {:error, reason} ->
            Logger.error("Failed to update credential: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to refresh token: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Ensures a credential has a valid (non-expired) token.
  Refreshes if expired or about to expire (within 5 minutes).
  """
  def ensure_valid_token(credential) do
    buffer_seconds = 300

    if DateTime.compare(
         credential.expires_at,
         DateTime.add(DateTime.utc_now(), buffer_seconds, :second)
       ) == :lt do
      Logger.info("Token expired or expiring soon, refreshing for user: #{credential.user_id}")
      refresh_credential(credential)
    else
      Logger.debug("Token is still valid for user: #{credential.user_id}")
      {:ok, credential}
    end
  end
end
