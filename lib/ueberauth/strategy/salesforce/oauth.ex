defmodule Ueberauth.Strategy.Salesforce.OAuth do
  @moduledoc """
  OAuth2 for Salesforce.

  Add `client_id` and `client_secret` to your configuration:

      config :ueberauth, Ueberauth.Strategy.Salesforce.OAuth,
        client_id: System.get_env("SALESFORCE_CLIENT_ID"),
        client_secret: System.get_env("SALESFORCE_CLIENT_SECRET")
  """

  use OAuth2.Strategy

  import OAuth2.Client, only: [put_param: 3, put_header: 3]

  @defaults [
    strategy: __MODULE__,
    site: "https://login.salesforce.com",
    authorize_url: "https://login.salesforce.com/services/oauth2/authorize",
    token_url: "https://login.salesforce.com/services/oauth2/token"
  ]

  @doc """
  Construct a client for requests to Salesforce.

  This will be setup automatically for you in `Ueberauth.Strategy.Salesforce`.

  These options are only useful for usage outside the normal callback phase of Ueberauth.
  """
  def client(opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__, [])

    opts =
      @defaults
      |> Keyword.merge(config)
      |> Keyword.merge(opts)

    json_library = Ueberauth.json_library()

    OAuth2.Client.new(opts)
    |> OAuth2.Client.put_serializer("application/json", json_library)
  end

  @doc """
  Provides the authorize url for the request phase of Ueberauth.
  """
  def authorize_url!(params \\ [], opts \\ []) do
    opts
    |> client()
    |> OAuth2.Client.authorize_url!(params)
  end

  @doc """
  Fetches an access token from the Salesforce token endpoint.
  """
  def get_access_token(params \\ [], opts \\ []) do
    require Logger

    # Debug: Check if client credentials are configured
    config = Application.get_env(:ueberauth, __MODULE__, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    Logger.info("Salesforce token exchange starting")
    Logger.info("Client ID configured: #{if client_id, do: String.slice(client_id, 0, 10) <> "...", else: "MISSING"}")
    Logger.info("Client Secret configured: #{if client_secret, do: "YES", else: "MISSING"}")

    case client(opts) |> OAuth2.Client.get_token(params) do
      {:ok, %OAuth2.Client{token: %OAuth2.AccessToken{} = token, params: raw_params}} ->
        Logger.info("Salesforce token exchange successful")
        Logger.info("Salesforce token returned: #{inspect(token)}")
        Logger.info("Salesforce token raw_params: #{inspect(raw_params)}")
        # Ensure instance_url is present in token.other_params for downstream use
        instance_url = raw_params["instance_url"] || token.other_params["instance_url"]
        new_other_params = Map.put(token.other_params, "instance_url", instance_url)
        token = %OAuth2.AccessToken{token | other_params: new_other_params}
        {:ok, token}

      {:error, %OAuth2.Response{body: body} = response} ->
        Logger.error("Salesforce token exchange failed with response: #{inspect(response)}")
        error_code = body["error"] || "unknown_error"
        error_description = body["error_description"] || "Token exchange failed"
        {:error, {error_code, error_description}}

      {:error, %OAuth2.Error{reason: reason}} ->
        Logger.error("Salesforce token exchange OAuth2 error: #{inspect(reason)}")
        {:error, {"oauth2_error", inspect(reason)}}

      {:error, error} ->
        Logger.error("Salesforce token exchange unexpected error: #{inspect(error)}")
        {:error, {"unexpected_error", inspect(error)}}
    end
  end

  @spec get_user_info(OAuth2.AccessToken.t()) ::
          {:error, OAuth2.Response.t()} | {:ok, binary() | list() | map()}
  @doc """
  Fetches user info from Salesforce using the identity URL.
  """
  def get_user_info(%OAuth2.AccessToken{} = token) do
    require Logger

    # Salesforce returns an `id` field in the token response which is the identity URL
    identity_url = token.other_params["id"]
    Logger.info("Salesforce identity URL: #{identity_url}")

    if identity_url do
      # Create a proper OAuth2 client with the token for authenticated requests
      client = %OAuth2.Client{
        token: token,
        serializers: %{"application/json" => Jason}
      }

      case OAuth2.Client.get(client, identity_url) do
        {:ok, %OAuth2.Response{status_code: 200, body: user}} ->
          Logger.info("Salesforce user info fetched successfully")
          {:ok, user}

        {:ok, %OAuth2.Response{} = response} ->
          Logger.error("Salesforce user info fetch failed: #{inspect(response)}")
          {:error, response}

        {:error, error} ->
          Logger.error("Salesforce user info error: #{inspect(error)}")
          {:error, %OAuth2.Response{status_code: 500, body: inspect(error)}}
      end
    else
      Logger.error("No identity URL found in Salesforce token response")
      {:error, %OAuth2.Response{status_code: 500, body: "No identity URL found in token response"}}
    end
  end

  @doc """
  Refreshes an access token.
  """
  def refresh_access_token(refresh_token, opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__, [])

    params = [
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: config[:client_id],
      client_secret: config[:client_secret]
    ]

    case client(opts) |> OAuth2.Client.get_token(params) do
      {:ok, %OAuth2.Client{token: token}} -> {:ok, token}
      {:error, error} -> {:error, error}
    end
  end


  # OAuth2.Strategy callbacks

  @impl OAuth2.Strategy
  def authorize_url(client, params) do
    OAuth2.Strategy.AuthCode.authorize_url(client, params)
  end

  @impl OAuth2.Strategy
  def get_token(client, params, headers) do
    # Extract code_verifier from params if present for PKCE
    {code_verifier, remaining_params} = Keyword.pop(params, :code_verifier)

    # Get client credentials from config
    config = Application.get_env(:ueberauth, __MODULE__, [])

    client = client
      |> put_param(:grant_type, "authorization_code")
      |> put_param(:client_id, config[:client_id])
      |> put_param(:client_secret, config[:client_secret])
      |> put_header("Content-Type", "application/x-www-form-urlencoded")

    # Add code_verifier to client params if present (for PKCE)
    client = if code_verifier do
      put_param(client, :code_verifier, code_verifier)
    else
      client
    end

    OAuth2.Strategy.AuthCode.get_token(client, remaining_params, headers)
  end
end
