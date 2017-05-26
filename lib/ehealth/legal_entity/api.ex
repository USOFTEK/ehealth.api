defmodule EHealth.LegalEntity.API do
  @moduledoc """
  The boundary for the LegalEntity system.
  """

  import EHealth.Utils.Connection, only: [get_consumer_id: 1]
  import EHealth.Utils.Pipeline

  alias Ecto.Date
  alias Ecto.UUID
  alias EHealth.API.PRM
  alias EHealth.API.Mithril
  alias EHealth.API.MediaStorage
  alias EHealth.OAuth.API, as: OAuth
  alias EHealth.LegalEntity.Validator
  alias EHealth.EmployeeRequest.API

  require Logger

  @employee_request_status "NEW"
  @employee_request_type "OWNER"

  def get_legal_entity_by_id(id, headers) do
    id
    |> PRM.get_legal_entity_by_id(headers)
    |> OAuth.get_client(headers)
    |> fetch_data()
  end

  def create_legal_entity(attrs, headers) do
    attrs
    |> Validator.decode_and_validate()
    |> process_request(attrs, headers)
  end

  # for testing without signed content
  def process_request({:ok, _} = pipe_data, attrs, headers) do
    pipe_data
    |> search_legal_entity_in_prm(headers)
    |> prepare_legal_entity_id()
    |> store_signed_content(attrs, headers)
    |> put_legal_entity_to_prm(headers)
    |> get_oauth_credentials(headers)
    |> prepare_security_data()
    |> update_legal_entity_status(headers)
    |> create_employee_request()
  end
  def process_request({:error, _} = err, _attrs, _headers), do: err
  def process_request(err, _attrs, _headers), do: {:error, err}

  def search_legal_entity_in_prm({:ok, %{legal_entity_request: %{"edrpou" => edrpou}} = pipe_data}, headers) do
    edrpou
    |> PRM.get_legal_entity_by_edrpou(headers)
    |> put_success_api_response_in_pipe(:legal_entity_prm, pipe_data)
  end

  @doc """
  Legal Entity not found in PRM. Generate ID for Legal Entity. Set flow as create
  """
  def prepare_legal_entity_id({:ok, %{legal_entity_prm: %{"data" => []}} = pipe_data}) do
    data = %{
      legal_entity_id: UUID.generate(),
      legal_entity_flow: :create
    }
    {:ok, Map.merge(pipe_data, data)}
  end

  @doc """
  Legal Entity found in PRM. Set flow as update
  """
  def prepare_legal_entity_id({:ok, %{legal_entity_prm: %{"data" => [legal_entity]}} = pipe_data}) do
    data = %{
      legal_entity_id: Map.fetch!(legal_entity, "id"),
      legal_entity_flow: :update
    }
    {:ok, Map.merge(pipe_data, data)}
  end

  def prepare_legal_entity_id(err), do: err

  @doc """
  Creates signed url and store signed content in GCS
  """
  def store_signed_content({:ok, pipe_data}, input, headers) do
    input
    |> Map.fetch!("signed_legal_entity_request")
    |> MediaStorage.store_signed_content(Map.fetch!(pipe_data, :legal_entity_id), headers)
    |> validate_api_response(pipe_data, "Cannot store signed content")
  end
  def store_signed_content(err, _input, _headers), do: err

  @doc """
  Creates new Legal Entity in PRM
  """
  def put_legal_entity_to_prm({:ok, %{legal_entity_flow: :create} = pipe_data}, headers) do
    consumer_id = get_consumer_id(headers)

    creation_data = %{
      "id" => Map.fetch!(pipe_data, :legal_entity_id),
      "status" => "NEW",
      "inserted_by" => consumer_id,
      "updated_by" => consumer_id
    }

    pipe_data
    |> Map.fetch!(:legal_entity_request)
    |> Map.merge(creation_data)
    |> PRM.create_legal_entity(headers)
    |> put_success_api_response_in_pipe(:legal_entity_prm, pipe_data)
  end

  @doc """
  Updates Legal Entity that exists and creates new Employee request in IL.
  """
  def put_legal_entity_to_prm({:ok, %{legal_entity_flow: :update} = pipe_data}, headers) do
    pipe_data
    |> Map.fetch!(:legal_entity_request)
    |> Map.drop(["edrpou", "kveds"]) # filter immutable data
    |> Map.put("updated_by", get_consumer_id(headers))
    |> PRM.update_legal_entity(Map.fetch!(pipe_data, :legal_entity_id), headers)
    |> put_success_api_response_in_pipe(:legal_entity_prm, pipe_data)
  end
  def put_legal_entity_to_prm(err, _headers), do: err

  @doc """
  Creates new OAuth client in Mithril API
  """
  def get_oauth_credentials({:ok, %{legal_entity_flow: :create} = pipe_data}, headers) do
    redirect_uri =
      pipe_data
      |> Map.fetch!(:legal_entity_request)
      |> Map.fetch!("security")
      |> Map.fetch!("redirect_uri")

    pipe_data
    |> Map.fetch!(:legal_entity_prm)
    |> Map.fetch!("data")
    |> OAuth.create_client(redirect_uri, headers)
    |> put_success_api_response_in_pipe(:oauth_client, pipe_data)
  end

  @doc """
  Get OAuth client from Mithril API
  """
  def get_oauth_credentials({:ok, %{legal_entity_flow: :update} = pipe_data}, headers) do
    pipe_data
    |> Map.fetch!(:legal_entity_id)
    |> Mithril.get_client(headers)
    |> put_success_api_response_in_pipe(:oauth_client, pipe_data)
  end
  def get_oauth_credentials(err, _headers), do: err

  def prepare_security_data({:ok, pipe_data}) do
    oauth_client = pipe_data |> Map.fetch!(:oauth_client) |> Map.fetch!("data")

    security = %{
      "client_id" => Map.get(oauth_client, "id"),
      "client_secret" => Map.get(oauth_client, "secret"),
      "redirect_uri" => Map.get(oauth_client, "redirect_uri")
    }

    put_in_pipe(security, :security, pipe_data)
  end
  def prepare_security_data(err), do: err

  def update_legal_entity_status({:ok, pipe_data}, headers) do
    pipe_data
    |> Map.fetch!(:legal_entity_prm)
    |> Map.fetch!("data")
    |> Map.fetch!("edrpou")
    |> PRM.check_msp_state_property_status(headers)
    |> set_legal_entity_status(Map.fetch!(pipe_data, :legal_entity_id), headers)
    |> put_success_api_response_in_pipe(:legal_entity_prm, pipe_data)
  end
  def update_legal_entity_status(err, _headers), do: err

  def set_legal_entity_status({:ok, %{"data" => []}}, id, headers) do
    PRM.update_legal_entity(%{"status" => "NOT_VERIFIED"}, id, headers)
  end

  def set_legal_entity_status({:ok, %{"data" => [_edrpou_in_registry]}}, id, headers) do
    PRM.update_legal_entity(%{"status" => "VERIFIED"}, id, headers)
  end

  @doc """
  Create Employee request
  Specification: https://edenlab.atlassian.net/wiki/display/EH/IL.Create+employee+request
  """
  def create_employee_request({:ok, pipe_data}) do
    id = Map.fetch!(pipe_data, :legal_entity_id)
    party =
      pipe_data
      |> Map.fetch!(:legal_entity_request)
      |> Map.fetch!("owner")

    id
    |> prepare_employee_request_data(party)
    |> API.create_employee_request()
    |> validate_api_response(pipe_data, "Cannot create employee request for Legal Entity #{id}.")
  end
  def create_employee_request(err), do: err

  def prepare_employee_request_data(legal_entity_id, party) do
    request = %{
        "legal_entity_id" => legal_entity_id,
        "position" => Map.fetch!(party, "position"),
        "status" => @employee_request_status,
        "employee_type" => @employee_request_type,
        "start_date" => Date.to_iso8601(Date.utc()),
        "party" => party
      }
    %{"employee_request" => request}
  end

  def fetch_data({:ok, %{"data" => data}, secret}), do: {:ok, data, secret}
  def fetch_data(err), do: err#
end
