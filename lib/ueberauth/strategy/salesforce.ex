defmodule Ueberauth.Strategy.Salesforce do
  @moduledoc """
  Salesforce Strategy for Ueberauth.
  """

  use Ueberauth.Strategy,
    uid_field: :organization_id,
    default_scope: "id api refresh_token",
    oauth2_module: Ueberauth.Strategy.Salesforce.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles initial request for Salesforce authentication.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    # Generate PKCE parameters
    code_verifier = generate_code_verifier()
    code_challenge = generate_code_challenge(code_verifier)

    # Store code_verifier in session for later use in callback
    conn = put_session(conn, :salesforce_code_verifier, code_verifier)

    opts =
      [scope: scopes, redirect_uri: callback_url(conn),
       code_challenge: code_challenge,
       code_challenge_method: "S256"]
      |> with_optional(:prompt, conn)
      |> with_param(:prompt, conn)
      |> with_state_param(conn)

    redirect!(conn, Ueberauth.Strategy.Salesforce.OAuth.authorize_url!(opts))
  end

  @doc """
  Handles the callback from Salesforce.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    code_verifier = get_session(conn, :salesforce_code_verifier)
    opts = [redirect_uri: callback_url(conn)]

    require Logger
    Logger.info("Salesforce callback received with code: #{String.slice(code, 0, 10)}...")
    Logger.info("Code verifier from session: #{code_verifier && String.slice(code_verifier, 0, 10)}...")

    case Ueberauth.Strategy.Salesforce.OAuth.get_access_token([code: code, code_verifier: code_verifier], opts) do
      {:ok, token} ->
        Logger.info("Salesforce token exchange successful")
        fetch_user(conn, token)

      {:error, {error_code, error_description}} ->
        Logger.error("Salesforce token exchange failed: #{error_code} - #{error_description}")
        set_errors!(conn, [error(error_code, error_description)])
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up the private area of the connection used for passing the raw Salesforce response around during the callback.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:salesforce_user, nil)
    |> put_private(:salesforce_token, nil)
  end

  @doc """
  Fetches the uid field from the Salesforce response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string()

    conn.private.salesforce_user[uid_field]
  end

  @doc """
  Includes the credentials from the Salesforce response.
  """
  def credentials(conn) do
    token = conn.private.salesforce_token

    %Credentials{
      expires: true,
      expires_at: token.expires_at,
      scopes: String.split(token.other_params["scope"] || "", " "),
      token: token.access_token,
      refresh_token: token.refresh_token,
      token_type: token.token_type
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.salesforce_user

    %Info{
      email: user["email"],
      name: user["display_name"] || user["username"],
      first_name: user["first_name"],
      last_name: user["last_name"]
    }
  end

  @doc """
  Stores the raw information obtained from the Salesforce callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.salesforce_token,
        user: conn.private.salesforce_user
      }
    }
  end

  defp fetch_user(conn, token) do
    conn = put_private(conn, :salesforce_token, token)

    # Debug: Log token structure to help diagnose issues
    require Logger
    Logger.info("Salesforce token received: #{inspect(token)}")
    Logger.info("Token other_params: #{inspect(token.other_params)}")

    # Salesforce returns the identity URL in the token response
    case Ueberauth.Strategy.Salesforce.OAuth.get_user_info(token) do
      {:ok, user} ->
        Logger.info("Salesforce user info fetched successfully: #{inspect(user)}")
        put_private(conn, :salesforce_user, user)

      # Handle error cases if the function signature changes
      other ->
        Logger.error("Salesforce user fetch unexpected result: #{inspect(other)}")
        set_errors!(conn, [error("fetch_user", "Failed to fetch user: #{inspect(other)}")])
    end
  end

  defp with_param(opts, key, conn) do
    if value = conn.params[to_string(key)] do
      Keyword.put(opts, key, value)
    else
      opts
    end
  end

  defp with_optional(opts, key, conn) do
    if option(conn, key) do
      Keyword.put(opts, key, option(conn, key))
    else
      opts
    end
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end

  # PKCE helper functions
  defp generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(code_verifier) do
    :crypto.hash(:sha256, code_verifier)
    |> Base.url_encode64(padding: false)
  end
end
