defmodule Explorer.Chain do
  @moduledoc """
    Represents statistics about the chain.
  """

  import Ecto.Query

  alias Explorer.Block
  alias Explorer.Repo
  alias Ecto.Adapters.SQL

  defstruct [
    number: 0, timestamp: nil, average_time: nil, transaction_count: 0,
    skipped_blocks: 0, lag: nil, block_velocity: 0,
    transaction_velocity: 0
  ]

  @average_time_query """
    SELECT coalesce(avg(difference), interval '0 seconds')
    FROM (
      SELECT timestamp - lag(timestamp) over (order by timestamp) as difference
      FROM blocks
      ORDER BY number DESC
      LIMIT 100
    ) t
  """

  @transaction_count_query """
    SELECT count(transactions.id)
      FROM transactions
      JOIN block_transactions ON block_transactions.transaction_id = transactions.id
      JOIN blocks ON blocks.id = block_transactions.block_id
      WHERE blocks.timestamp > NOW() - interval '1 day'
  """

  @skipped_blocks_query """
    SELECT COUNT(missing_number)
      FROM generate_series(0, $1, 1) AS missing_number
      WHERE missing_number NOT IN (SELECT blocks.number FROM blocks)
  """

  @lag_query """
    SELECT coalesce(avg(lag), interval '0 seconds')
    FROM (
      SELECT inserted_at - timestamp AS lag
      FROM blocks
      WHERE blocks.inserted_at > NOW() - interval '1 hour'
        AND blocks.timestamp > NOW() - interval '1 hour'
    ) t
  """

  @block_velocity_query """
    SELECT count(blocks.id) / 60
      FROM blocks
      WHERE blocks.inserted_at > NOW() - interval '1 hour'
  """

  @transaction_velocity_query """
    SELECT count(transactions.id) / 60
      FROM transactions
      WHERE transactions.inserted_at > NOW() - interval '1 hour'
  """

  def fetch do
    latest_block = Block |> Block.latest() |> limit(1) |> Repo.one()
    %Explorer.Chain{
      number: latest_block.number,
      timestamp: latest_block.timestamp,
      average_time: query_duration(@average_time_query),
      transaction_count: query_value(@transaction_count_query),
      skipped_blocks: query_value(@skipped_blocks_query, [latest_block.number]),
      lag: query_duration(@lag_query),
      block_velocity: query_value(@block_velocity_query),
      transaction_velocity: query_value(@transaction_velocity_query)
    }
  end

  defp query_value(query, args \\ []) do
    results = SQL.query!(Repo, query, args)
    results.rows |> List.first() |> List.first()
  end

  defp query_duration(query) do
    results = SQL.query!(Repo, query, [])
    {:ok, value} = results.rows
      |> List.first()
      |> List.first()
      |> Timex.Ecto.Time.load()
    value
  end
end