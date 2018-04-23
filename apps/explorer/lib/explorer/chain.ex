defmodule Explorer.Chain do
  @moduledoc """
  The chain context.
  """

  import Ecto.Query, only: [from: 2, order_by: 2, preload: 2, where: 2, where: 3]

  alias Ecto.Multi
  alias Explorer.Chain.{Address, Block, Hash, InternalTransaction, Log, Receipt, Transaction, Wei}
  alias Explorer.Repo

  # Types

  @typedoc """
  The name of an association on the `t:Ecto.Schema.t/0`
  """
  @type association :: atom()

  @typedoc """
  * `:optional` - the association is optional and only needs to be loaded if available
  * `:required` - the association is required and MUST be loaded.  If it is not available, then the parent struct
      SHOULD NOT be returned.
  """
  @type necessity :: :optional | :required

  @typedoc """
  The `t:necessity/0` of each association that should be loaded
  """
  @type necessity_by_association :: %{association => necessity}

  @typedoc """
  Pagination params used by `scrivener`
  """
  @type pagination :: map()

  @typep after_hash_option :: {:after_hash, Hash.t()}
  @typep inserted_after_option :: {:inserted_after, DateTime.t()}
  @typep necessity_by_association_option :: {:necessity_by_association, necessity_by_association}
  @typep pagination_option :: {:pagination, pagination}

  # Functions

  def block_count do
    Repo.one(from(b in Block, select: count(b.id)))
  end

  @doc """
  Finds all `t:Explorer.Chain.Transaction.t/0` in the `t:Explorer.Chain.Block.t/0`.

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Transaction.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Transaction.t/0` will not be included in the page `entries`.
  * `:pagination` - pagination params to pass to scrivener.
  """
  @spec block_to_transactions(Block.t()) :: %Scrivener.Page{entries: [Transaction.t()]}
  @spec block_to_transactions(Block.t(), [necessity_by_association_option | pagination_option]) :: %Scrivener.Page{
          entries: [Transaction.t()]
        }
  def block_to_transactions(%Block{hash: block_hash}, options \\ []) when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    pagination = Keyword.get(options, :pagination, %{})

    query =
      from(
        transaction in Transaction,
        inner_join: block in assoc(transaction, :block),
        where: block.hash == ^block_hash,
        order_by: [desc: transaction.inserted_at, desc: transaction.hash]
      )

    query
    |> join_associations(necessity_by_association)
    |> Repo.paginate(pagination)
  end

  @doc """
  Counts the number of `t:Explorer.Chain.Transaction.t/0` in the `block`.
  """
  @spec block_to_transaction_count(Block.t()) :: non_neg_integer()
  def block_to_transaction_count(%Block{hash: block_hash}) do
    query =
      from(
        transaction in Transaction,
        where: transaction.block_hash == ^block_hash
      )

    Repo.aggregate(query, :count, :hash)
  end

  @doc """
  How many blocks have confirmed `block` based on the current `max_block_number`
  """
  @spec confirmations(Block.t(), [{:max_block_number, Block.block_number()}]) :: non_neg_integer()
  def confirmations(%Block{number: number}, named_arguments) when is_list(named_arguments) do
    max_block_number = Keyword.fetch!(named_arguments, :max_block_number)

    max_block_number - number
  end

  @doc """
  Creates an address.

      iex> {:ok, %Explorer.Chain.Address{hash: hash}} = Explorer.Chain.create_address(
      ...>   %{hash: "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"}
      ...> )
      ...> to_string(hash)
      "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"

  A `String.t/0` value for `Explorer.Chain.Addres.t/0` `hash` must have 40 hexadecimal characters after the `0x` prefix
  to prevent short- and long-hash transcription errors.

      iex> {:error, %Ecto.Changeset{errors: errors}} = Explorer.Chain.create_address(
      ...>   %{hash: "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0"}
      ...> )
      ...> errors
      [hash: {"is invalid", [type: Explorer.Chain.Hash.Truncated, validation: :cast]}]
      iex> {:error, %Ecto.Changeset{errors: errors}} = Explorer.Chain.create_address(
      ...>   %{hash: "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0ba"}
      ...> )
      ...> errors
      [hash: {"is invalid", [type: Explorer.Chain.Hash.Truncated, validation: :cast]}]

  """
  @spec create_address(map()) :: {:ok, Address.t()} | {:error, Ecto.Changeset.t()}
  def create_address(attrs \\ %{}) do
    %Address{}
    |> Address.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Ensures that an `t:Explorer.Address.t/0` exists with the given `hash`.

  If a `t:Explorer.Address.t/0` with `hash` already exists, it is returned

      iex> {:ok, %Explorer.Chain.Address{hash: existing_hash}} = Explorer.Chain.create_address(
      ...>   %{hash: "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"}
      ...> )
      iex> {:ok, %Explorer.Chain.Address{hash: found_hash}} = Explorer.Chain.ensure_hash_address(existing_hash)
      iex> found_hash == existing_hash
      true

  If a `t:Explorer.Address.t/0` does not exist with `hash`, it is created and returned

      iex> {:ok, new_hash} = Explorer.Chain.string_to_address_hash("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b")
      iex> Explorer.Chain.hash_to_address(new_hash)
      {:error, :not_found}
      iex> {:ok, %Explorer.Chain.Address{hash: created_hash}} = Explorer.Chain.ensure_hash_address(new_hash)
      iex> created_hash == new_hash
      true

  There is a chance of a race condition when interacting with the database: the `t:Explorer.Address.t/0` may not exist
  when first checked, then already exist when it is tried to be created because another connection creates the addres,
  then another process deletes the address after this process's connection see it was created, but before it can be
  retrieved.  In scenario, the address may be not found as only one retry is attempted to prevent infinite loops.

      Explorer.Addresses.ensure_hash_address(flicker_hash)
      {:error, :not_found}

  """
  @spec ensure_hash_address(Hash.Truncated.t()) :: {:ok, Address.t()} | {:error, :not_found}
  def ensure_hash_address(%Hash{byte_count: unquote(Hash.Truncated.byte_count())} = hash) do
    with {:error, :not_found} <- hash_to_address(hash),
         {:error, _} <- create_address(%{hash: hash}) do
      # assume race condition occurred and someone else created the address between the first
      # hash_to_address and create_address
      hash_to_address(hash)
    end
  end

  @doc """
  `t:Explorer.Chain.Transaction/0`s from `address`.

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Transaction.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Transaction.t/0` will not be included in the page `entries`.
  * `:pagination` - pagination params to pass to scrivener.

  """
  @spec from_address_to_transactions(Address.t(), [
          necessity_by_association_option | pagination_option
        ]) :: %Scrivener.Page{entries: [Transaction.t()]}
  def from_address_to_transactions(address = %Address{}, options \\ []) when is_list(options) do
    address_to_transactions(address, Keyword.put(options, :direction, :from))
  end

  @doc """
  TODO
  """
  def get_latest_block do
    Repo.one(from(b in Block, limit: 1, order_by: [desc: b.number]))
  end

  @doc """
  The `t:Explorer.Chain.Transaction.t/0` `gas_price` of the `transaction` in `unit`.
  """
  @spec gas_price(Transaction.t(), :wei) :: Wei.t()
  @spec gas_price(Transaction.t(), :gwei) :: Wei.gwei()
  @spec gas_price(Transaction.t(), :ether) :: Wei.ether()
  def gas_price(%Transaction{gas_price: gas_price}, unit) do
    Wei.to(gas_price, unit)
  end

  @doc """
  Converts `t:Explorer.Chain.Address.t/0` `hash` to the `t:Explorer.Chain.Address.t/0` with that `hash`.

  Returns `{:ok, %Explorer.Chain.Address{}}` if found

      iex> {:ok, %Explorer.Chain.Address{hash: hash}} = Explorer.Chain.create_address(
      ...>   %{hash: "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"}
      ...> )
      iex> {:ok, %Explorer.Chain.Address{hash: found_hash}} = Explorer.Chain.hash_to_address(hash)
      iex> found_hash == hash
      true

  Returns `{:error, :not_found}` if not found

      iex> {:ok, hash} = Explorer.Chain.string_to_address_hash("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed")
      iex> Explorer.Chain.hash_to_address(hash)
      {:error, :not_found}

  """
  @spec hash_to_address(Hash.Truncated.t()) :: {:ok, Address.t()} | {:error, :not_found}
  def hash_to_address(%Hash{byte_count: unquote(Hash.Truncated.byte_count())} = hash) do
    query =
      from(
        address in Address,
        where: address.hash == ^hash,
        preload: [:credit, :debit]
      )

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      address -> {:ok, address}
    end
  end

  @doc """
  Converts the `t:t/0` to string representation shown to users.

      iex> Explorer.Chain.hash_to_iodata(
      ...>   %Explorer.Chain.Hash{
      ...>     byte_count: 32,
      ...>     bytes: <<0x9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b ::
      ...>              big-integer-size(32)-unit(8)>>
      ...>   }
      ...> )
      [
        "0x",
        ['9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b']
      ]

  Always pads number, so that it is a valid format for casting.

      iex> Explorer.Chain.hash_to_iodata(
      ...>   %Explorer.Chain.Hash{
      ...>     byte_count: 32,
      ...>     bytes: <<0x1234567890abcdef :: big-integer-size(32)-unit(8)>>
      ...>   }
      ...> )
      [
        "0x",
        [
          [
            [
              [
                [['000', 48, 48, 48], '000', 48, 48, 48],
                ['000', 48, 48, 48],
                '000',
                48,
                48,
                48
              ],
              [['000', 48, 48, 48], '000', 48, 48, 48],
              ['000', 48, 48, 48],
              '000',
              48,
              48,
              48
            ],
            49,
            50,
            51,
            52,
            53,
            54,
            55,
            56,
            57,
            48,
            97,
            98,
            99,
            100,
            101,
            102
          ]
        ]
      ]

  """
  @spec hash_to_iodata(Hash.t()) :: iodata()
  def hash_to_iodata(hash) do
    Hash.to_iodata(hash)
  end

  @doc """
  Converts `t:Explorer.Chain.Transaction.t/0` `hash` to the `t:Explorer.Chain.Transaction.t/0` with that `hash`.

  Returns `{:ok, %Explorer.Chain.Transaction{}}` if found

      iex> %Transaction{hash: hash} = insert(:transaction)
      iex> {:ok, %Explorer.Chain.Transaction{hash: found_hash}} = Explorer.Chain.hash_to_transaction(hash)
      iex> found_hash == hash
      true

  Returns `{:error, :not_found}` if not found

      iex> {:ok, hash} = Explorer.Chain.string_to_transaction_hash(
      ...>   "0x9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b"
      ...> )
      iex> Explorer.Chain.hash_to_transaction(hash)
      {:error, :not_found}

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Transaction.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Transaction.t/0` will not be included in the page `entries`.
  """
  @spec hash_to_transaction(Hash.Full.t(), [necessity_by_association_option]) ::
          {:ok, Transaction.t()} | {:error, :not_found}
  def hash_to_transaction(%Hash{byte_count: unquote(Hash.Full.byte_count())} = hash, options \\ [])
      when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    Transaction
    |> where(hash: ^hash)
    |> join_associations(necessity_by_association)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      transaction -> {:ok, transaction}
    end
  end

  def import_blocks(raw_blocks, internal_transactions, receipts) do
    {blocks, transactions} = extract_blocks(raw_blocks)

    Multi.new()
    |> Multi.run(:blocks, &insert_blocks(&1, blocks))
    |> Multi.run(:transactions, &insert_transactions(&1, transactions))
    |> Multi.run(:internal, &insert_internal(&1, internal_transactions))
    |> Multi.run(:receipts, &insert_receipts(&1, receipts))
    |> Multi.run(:logs, &insert_logs(&1))
    |> Repo.transaction()
  end

  def internal_transaction_count do
    Repo.one(from(t in InternalTransaction, select: count(t.id)))
  end

  @doc """
  Finds all `t:Explorer.Chain.Transaction.t/0` in the `t:Explorer.Chain.Block.t/0`.

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Block.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Transaction.t/0` will not be included in the page `entries`.
  * `:pagination` - pagination params to pass to scrivener.

  """
  @spec list_blocks([necessity_by_association_option | pagination_option]) :: %Scrivener.Page{
          entries: [Block.t()]
        }
  def list_blocks(options \\ []) when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    pagination = Keyword.get(options, :pagination, %{})

    Block
    |> join_associations(necessity_by_association)
    |> order_by(desc: :number)
    |> Repo.paginate(pagination)
  end

  def log_count do
    Repo.one(from(l in Log, select: count(l.id)))
  end

  @doc """
  The maximum `t:Explorer.Chain.Block.t/0` `number`
  """
  @spec max_block_number() :: Block.block_number()
  def max_block_number do
    Repo.aggregate(Block, :max, :number)
  end

  @doc """
  TODO
  """
  def missing_block_numbers do
    {:ok, {_, missing_count, missing_ranges}} =
      Repo.transaction(fn ->
        query = from(b in Block, select: b.number, order_by: [asc: b.number])

        query
        |> Repo.stream(max_rows: 1000)
        |> Enum.reduce({-1, 0, []}, fn
          num, {prev, missing_count, acc} when prev + 1 == num ->
            {num, missing_count, acc}

          num, {prev, missing_count, acc} ->
            {num, missing_count + (num - prev - 1), [{prev + 1, num - 1} | acc]}
        end)
      end)

    {missing_count, missing_ranges}
  end

  @doc """
  Finds `t:Explorer.Chain.Block.t/0` with `number`
  """
  @spec number_to_block(Block.block_number()) :: {:ok, Block.t()} | {:error, :not_found}
  def number_to_block(number) do
    Block
    |> where(number: ^number)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  def receipt_count do
    Repo.one(from(r in Receipt, select: count(r.id)))
  end

  @doc """
  Returns the list of collated transactions that occurred recently (10).

      iex> 2 |> insert_list(:transaction) |> validate()
      iex> insert(:transaction) # unvalidated transaction
      iex> 8 |> insert_list(:transaction) |> validate()
      iex> recent_collated_transactions = Explorer.Chain.recent_collated_transactions()
      iex> length(recent_collated_transactions)
      10
      iex> Enum.all?(recent_collated_transactions, fn %Explorer.Chain.Transaction{block_hash: block_hash} ->
      ...>   !is_nil(block_hash)
      ...> end)
      true

  A `t:Explorer.Chain.Transaction.t/0` `hash` can be supplied to the `:after_hash` option, then only transactions in
  after the transaction (with a greater index) in the same block or in a later block (with a greater number) will be
  returned.  This can be used to generate paging for collated transaction.

      iex> first_block = insert(:block, number: 1)
      iex> first_transaction_in_first_block = insert(:transaction, block_hash: first_block.hash, index: 0)
      iex> second_transaction_in_first_block = insert(:transaction, block_hash: first_block.hash, index: 1)
      iex> second_block = insert(:block, number: 2)
      iex> first_transaction_in_second_block = insert(:transaction, block_hash: second_block.hash, index: 0)
      iex> after_first_transaciton_in_first_block = Explorer.Chain.recent_collated_transactions(
      ...>   after_hash: first_transaction_in_first_block.hash
      ...> )
      iex> length(after_first_transaciton_in_first_block)
      2
      iex> after_second_transaciton_in_first_block = Explorer.Chain.recent_collated_transactions(
      ...>   after_hash: second_transaction_in_first_block.hash
      ...> )
      iex> length(after_second_transaciton_in_first_block)
      1
      iex> after_first_transaciton_in_second_block = Explorer.Chain.recent_collated_transactions(
      ...>   after_hash: first_transaction_in_second_block.hash
      ...> )
      iex> length(after_first_transaciton_in_second_block)
      0

  When there are no collated transactions, an empty list is returned.

     iex> insert(:transaction)
     iex> Explorer.Chain.recent_collated_transactions()
     []

  Using an unvalidated transaction's hash for `:after_hash` will also yield an empty list.

     iex> %Explorer.Chain.Transaction{hash: hash} = insert(:transaction)
     iex> insert(:transaction)
     iex> Explorer.Chain.recent_collated_transactions(after_hash: hash)
     []

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.InternalTransaction.t/0` has no associated record for that association,
      then the `t:Explorer.Chain.InternalTransaction.t/0` will not be included in the list.

  """
  @spec recent_collated_transactions([after_hash_option | necessity_by_association_option]) :: [Transaction.t()]
  def recent_collated_transactions(options \\ []) when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    query =
      from(
        transaction in Transaction,
        inner_join: block in assoc(transaction, :block),
        order_by: [desc: block.number, desc: transaction.index],
        limit: 10
      )

    query
    |> after_hash(options)
    |> join_associations(necessity_by_association)
    |> Repo.all()
  end

  @doc """
  Return the list of pending transactions that occurred recently (10).

      iex> 2 |> insert_list(:transaction)
      iex> :transaction |> insert() |> validate()
      iex> 8 |> insert_list(:transaction)
      iex> recent_pending_transactions = Explorer.Chain.recent_pending_transactions()
      iex> length(recent_pending_transactions)
      10
      iex> Enum.all?(recent_pending_transactions, fn %Explorer.Chain.Transaction{block_hash: block_hash} ->
      ...>   is_nil(block_hash)
      ...> end)
      true

  A `t:Explorer.Chain.Transaction.t/0` `inserted_at` can be supplied to the `:inserted_after` option, then only pending
  transactions inserted after that transaction will be returned.  This can be used to generate paging for pending
  transactions.

      iex> {:ok, first_inserted_at, 0} = DateTime.from_iso8601("2015-01-23T23:50:07Z")
      iex> insert(:transaction, inserted_at: first_inserted_at)
      iex> {:ok, second_inserted_at, 0} = DateTime.from_iso8601("2016-01-23T23:50:07Z")
      iex> insert(:transaction, inserted_at: second_inserted_at)
      iex> after_first_transaction = Explorer.Chain.recent_pending_transactions(inserted_after: first_inserted_at)
      iex> length(after_first_transaction)
      1
      iex> after_second_transaction = Explorer.Chain.recent_pending_transactions(inserted_after: second_inserted_at)
      iex> length(after_second_transaction)
      0

  When there are no pending transaction and a collated transaction's inserted_at is used, an empty list is returned

      iex> {:ok, first_inserted_at, 0} = DateTime.from_iso8601("2015-01-23T23:50:07Z")
      iex> :transaction |> insert(inserted_at: first_inserted_at) |> validate()
      iex> {:ok, second_inserted_at, 0} = DateTime.from_iso8601("2016-01-23T23:50:07Z")
      iex> :transaction |> insert(inserted_at: second_inserted_at) |> validate()
      iex> Explorer.Chain.recent_pending_transactions(after_inserted_at: first_inserted_at)
      []

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.InternalTransaction.t/0` has no associated record for that association,
      then the `t:Explorer.Chain.InternalTransaction.t/0` will not be included in the list.

  """
  @spec recent_pending_transactions([inserted_after_option | necessity_by_association_option]) :: [Transaction.t()]
  def recent_pending_transactions(options \\ []) when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    query =
      from(
        transaction in Transaction,
        where: is_nil(transaction.block_hash),
        order_by: [
          desc: transaction.inserted_at,
          # arbitary tie-breaker when inserted at is the same.  hash is random distribution, but using it keeps order
          # consistent at least
          desc: transaction.hash
        ],
        limit: 10
      )

    query
    |> inserted_after(options)
    |> join_associations(necessity_by_association)
    |> Repo.all()
  end

  @doc """
  The `string` must start with `0x`, then is converted to an integer and then to `t:Explorer.Chain.Hash.Truncated.t/0`.

      iex> Explorer.Chain.string_to_address_hash("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
      {
        :ok,
        %Explorer.Chain.Hash{
          byte_count: 20,
          bytes: <<0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed :: big-integer-size(20)-unit(8)>>
        }
      }

  `String.t` format must always have 40 hexadecimal digits after the `0x` base prefix.

      iex> Explorer.Chain.string_to_address_hash("0x0")
      :error

  """
  @spec string_to_address_hash(String.t()) :: {:ok, Hash.Truncated.t()} | :error
  def string_to_address_hash(string) when is_binary(string) do
    Hash.Truncated.cast(string)
  end

  @doc """
  The `string` must start with `0x`, then is converted to an integer and then to `t:Explorer.Chain.Hash.t/0`.

      iex> Explorer.Chain.string_to_block_hash(
      ...>   "0x9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b"
      ...> )
      {
        :ok,
        %Explorer.Chain.Hash{
          byte_count: 32,
          bytes: <<0x9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b :: big-integer-size(32)-unit(8)>>
        }
      }

  `String.t` format must always have 64 hexadecimal digits after the `0x` base prefix.

      iex> Explorer.Chain.string_to_block_hash("0x0")
      :error

  """
  @spec string_to_block_hash(String.t()) :: {:ok, Hash.t()} | :error
  def string_to_block_hash(string) when is_binary(string) do
    Hash.Full.cast(string)
  end

  @doc """
  The `string` must start with `0x`, then is converted to an integer and then to `t:Explorer.Chain.Hash.t/0`.

      iex> Explorer.Chain.string_to_transaction_hash(
      ...>  "0x9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b"
      ...> )
      {
        :ok,
        %Explorer.Chain.Hash{
          byte_count: 32,
          bytes: <<0x9fc76417374aa880d4449a1f7f31ec597f00b1f6f3dd2d66f4c9c6c445836d8b :: big-integer-size(32)-unit(8)>>
        }
      }

  `String.t` format must always have 64 hexadecimal digits after the `0x` base prefix.

      iex> Explorer.Chain.string_to_transaction_hash("0x0")
      :error

  """
  @spec string_to_transaction_hash(String.t()) :: {:ok, Hash.t()} | :error
  def string_to_transaction_hash(string) when is_binary(string) do
    Hash.Full.cast(string)
  end

  @doc """
  `t:Explorer.Chain.Transaction/0`s to `address`.

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Transaction.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Transaction.t/0` will not be included in the page `entries`.
  * `:pagination` - pagination params to pass to scrivener.

  """
  @spec to_address_to_transactions(Address.t(), [
          necessity_by_association_option | pagination_option
        ]) :: %Scrivener.Page{entries: [Transaction.t()]}
  def to_address_to_transactions(address = %Address{}, options \\ []) when is_list(options) do
    address_to_transactions(address, Keyword.put(options, :direction, :to))
  end

  @doc """
  Count of `t:Explorer.Chain.Transaction.t/0`.

  With no options or an explicit `pending: nil`, both collated and pending transactions will be counted.

      iex> insert(:transaction)
      iex> :transaction |> insert() |> validate()
      iex> Explorer.Chain.transaction_count()
      2
      iex> Explorer.Chain.transaction_count(pending: nil)
      2

  To count only collated transactions, pass `pending: false`.

      iex> 2 |> insert_list(:transaction)
      iex> 3 |> insert_list(:transaction) |> validate()
      iex> Explorer.Chain.transaction_count(pending: false)
      3

  To count only pending transactions, pass `pending: true`.

      iex> 2 |> insert_list(:transaction)
      iex> 3 |> insert_list(:transaction) |> validate()
      iex> Explorer.Chain.transaction_count(pending: true)
      2

  ## Options

  * `:pending`
    * `nil` - count all transactions
    * `true` - only count pending transactions
    * `false` - only count collated transactions

  """
  @spec transaction_count([{:pending, boolean()}]) :: non_neg_integer()
  def transaction_count(options \\ []) when is_list(options) do
    Transaction
    |> where_pending(options)
    |> Repo.aggregate(:count, :hash)
  end

  @doc """
  `t:Explorer.Chain.InternalTransaction/0`s in `t:Explorer.Chain.Transaction.t/0` with `hash`.

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.InternalTransaction.t/0` has no associated record for that association,
      then the `t:Explorer.Chain.InternalTransaction.t/0` will not be included in the list.

  """
  @spec transaction_hash_to_internal_transactions(Hash.Full.t()) :: [InternalTransaction.t()]
  def transaction_hash_to_internal_transactions(
        %Hash{byte_count: unquote(Hash.Full.byte_count())} = hash,
        options \\ []
      )
      when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    InternalTransaction
    |> for_parent_transaction(hash)
    |> join_associations(necessity_by_association)
    |> Repo.all()
  end

  @doc """
  Finds all `t:Explorer.Chain.Log.t/0`s for `t:Explorer.Chain.Transaction.t/0`.

  ## Options

  * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Log.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Log.t/0` will not be included in the page `entries`.
  * `:pagination` - pagination params to pass to scrivener.

  """
  @spec transaction_to_logs(Transaction.t(), [
          necessity_by_association_option | pagination_option
        ]) :: %Scrivener.Page{entries: [Log.t()]}
  def transaction_to_logs(%Transaction{hash: hash}, options \\ []) when is_list(options) do
    transaction_hash_to_logs(hash, options)
  end

  @doc """
  Converts `transaction` with its `receipt` loaded to the status of the `t:Explorer.Chain.Transaction.t/0`.

  ## Returns

  * `:failed` - the transaction failed without running out of gas
  * `:pending` - the transaction has not be confirmed in a block yet
  * `:out_of_gas` - the transaction failed because it ran out of gas
  * `:success` - the transaction has been confirmed in a block

  """
  @spec transaction_to_status(Transaction.t()) :: :failed | :pending | :out_of_gas | :success
  def transaction_to_status(%Transaction{receipt: nil}), do: :pending
  def transaction_to_status(%Transaction{receipt: %Receipt{status: 1}}), do: :success

  def transaction_to_status(%Transaction{
        gas: gas,
        receipt: %Receipt{gas_used: gas_used, status: 0}
      })
      when gas_used >= gas do
    :out_of_gas
  end

  def transaction_to_status(%Transaction{receipt: %Receipt{status: 0}}), do: :failed

  @doc """
  Updates `balance` of `t:Explorer.Address.t/0` with `hash`.

  If `t:Explorer.Address.t/0` with `hash` does not already exist, it is created first.
  """
  @spec update_balance(Hash.Truncated.t(), Address.balance()) ::
          {:ok, Address.t()} | {:error, Ecto.Changeset.t()} | {:error, reason :: term}
  def update_balance(%Hash{byte_count: unquote(Hash.Truncated.byte_count())} = hash, balance) do
    changes = %{
      balance: balance
    }

    with {:ok, address} <- ensure_hash_address(hash) do
      address
      |> Address.balance_changeset(changes)
      |> Repo.update()
    end
  end

  @doc """
  The `t:Explorer.Chain.Transaction.t/0` or `t:Explorer.Chain.InternalTransaction.t/0` `value` of the `transaction` in
  `unit`.
  """
  @spec value(InternalTransaction.t(), :wei) :: Wei.t()
  @spec value(InternalTransaction.t(), :gwei) :: Wei.gwei()
  @spec value(InternalTransaction.t(), :ether) :: Wei.ether()
  @spec value(Transaction.t(), :wei) :: Wei.t()
  @spec value(Transaction.t(), :gwei) :: Wei.gwei()
  @spec value(Transaction.t(), :ether) :: Wei.ether()
  def value(%type{value: value}, unit) when type in [InternalTransaction, Transaction] do
    Wei.to(value, unit)
  end

  ## Private Functions

  defp address_hash_to_transaction(
         %Hash{byte_count: unquote(Hash.Truncated.byte_count())} = address_hash,
         named_arguments
       )
       when is_list(named_arguments) do
    field =
      case Keyword.fetch!(named_arguments, :direction) do
        :to -> :to_address_hash
        :from -> :from_address_hash
      end

    necessity_by_association = Keyword.get(named_arguments, :necessity_by_association, %{})
    pagination = Keyword.get(named_arguments, :pagination, %{})

    Transaction
    |> join_associations(necessity_by_association)
    |> chronologically()
    |> where([t], field(t, ^field) == ^address_hash)
    |> Repo.paginate(pagination)
  end

  defp address_to_transactions(%Address{hash: address_hash}, options) when is_list(options) do
    address_hash_to_transaction(address_hash, options)
  end

  defp after_hash(query, options) do
    case Keyword.fetch(options, :after_hash) do
      {:ok, hash} ->
        from(
          transaction in query,
          inner_join: block in assoc(transaction, :block),
          join: hash_transaction in Transaction,
          on: hash_transaction.hash == ^hash,
          inner_join: hash_block in assoc(hash_transaction, :block),
          where:
            block.number > hash_block.number or
              (block.number == hash_block.number and transaction.index > hash_transaction.index)
        )

      :error ->
        query
    end
  end

  defp chronologically(query) do
    from(q in query, order_by: [desc: q.inserted_at, desc: q.hash])
  end

  defp extract_blocks(raw_blocks) do
    timestamps = timestamps()

    {blocks, transactions} =
      Enum.reduce(raw_blocks, {[], []}, fn raw_block, {blocks_acc, trans_acc} ->
        {:ok, block, transactions} = Block.extract(raw_block, timestamps)
        {[block | blocks_acc], trans_acc ++ transactions}
      end)

    {Enum.reverse(blocks), transactions}
  end

  defp for_parent_transaction(query, %Hash{byte_count: unquote(Hash.Full.byte_count())} = hash) do
    from(
      child in query,
      inner_join: transaction in assoc(child, :transaction),
      where: transaction.hash == ^hash
    )
  end

  defp insert_blocks(%{}, blocks) do
    {_, inserted_blocks} =
      Repo.safe_insert_all(
        Block,
        blocks,
        returning: [:id, :number],
        on_conflict: :replace_all,
        conflict_target: :number
      )

    {:ok, inserted_blocks}
  end

  defp insert_internal(%{transactions: transactions}, internal_transactions) do
    timestamps = timestamps()

    internals =
      Enum.flat_map(transactions, fn %{hash: hash, id: id} ->
        case Map.fetch(internal_transactions, hash) do
          {:ok, traces} ->
            Enum.map(traces, &InternalTransaction.extract(&1, id, timestamps))

          :error ->
            []
        end
      end)

    {_, inserted} = Repo.safe_insert_all(InternalTransaction, internals, on_conflict: :nothing)

    {:ok, inserted}
  end

  defp insert_logs(%{receipts: %{inserted: receipts, logs: logs_map}}) do
    logs_to_insert =
      Enum.reduce(receipts, [], fn receipt, acc ->
        case Map.fetch(logs_map, receipt.transaction_id) do
          {:ok, []} ->
            acc

          {:ok, [_ | _] = logs} ->
            logs = Enum.map(logs, &Map.put(&1, :receipt_id, receipt.id))
            logs ++ acc
        end
      end)

    {_, inserted_logs} = Repo.safe_insert_all(Log, logs_to_insert, returning: [:id])
    {:ok, inserted_logs}
  end

  defp insert_receipts(%{transactions: transactions}, raw_receipts) do
    timestamps = timestamps()

    {receipts_to_insert, logs_map} =
      Enum.reduce(transactions, {[], %{}}, fn trans, {receipts_acc, logs_acc} ->
        case Map.fetch(raw_receipts, trans.hash) do
          {:ok, raw_receipt} ->
            {receipt, logs} = Receipt.extract(raw_receipt, trans.id, timestamps)
            {[receipt | receipts_acc], Map.put(logs_acc, trans.id, logs)}

          :error ->
            {receipts_acc, logs_acc}
        end
      end)

    {_, inserted_receipts} =
      Repo.safe_insert_all(
        Receipt,
        receipts_to_insert,
        returning: [:id, :transaction_id]
      )

    {:ok, %{inserted: inserted_receipts, logs: logs_map}}
  end

  defp insert_transactions(%{blocks: blocks}, transactions) do
    blocks_map = for block <- blocks, into: %{}, do: {block.number, block}

    transactions =
      for transaction <- transactions do
        %{id: id} = Map.fetch!(blocks_map, transaction.block_number)

        transaction
        |> Map.put(:block_id, id)
        |> Map.delete(:block_number)
      end

    {_, inserted} = Repo.safe_insert_all(Transaction, transactions, returning: [:id, :hash])

    {:ok, inserted}
  end

  defp inserted_after(query, options) do
    case Keyword.fetch(options, :inserted_after) do
      {:ok, inserted_after} ->
        from(transaction in query, where: ^inserted_after < transaction.inserted_at)

      :error ->
        query
    end
  end

  defp join_association(query, association, necessity) when is_atom(association) do
    case necessity do
      :optional ->
        preload(query, ^association)

      :required ->
        from(q in query, inner_join: a in assoc(q, ^association), preload: [{^association, a}])
    end
  end

  defp join_associations(query, necessity_by_association) when is_map(necessity_by_association) do
    Enum.reduce(necessity_by_association, query, fn {association, join}, acc_query ->
      join_association(acc_query, association, join)
    end)
  end

  defp timestamps do
    now = Ecto.DateTime.utc()
    %{inserted_at: now, updated_at: now}
  end

  defp transaction_hash_to_logs(%Hash{byte_count: unquote(Hash.Full.byte_count())} = transaction_hash, options)
       when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    pagination = Keyword.get(options, :pagination, %{})

    query =
      from(
        log in Log,
        join: transaction in assoc(log, :transaction),
        where: transaction.hash == ^transaction_hash,
        order_by: [asc: :index]
      )

    query
    |> join_associations(necessity_by_association)
    |> Repo.paginate(pagination)
  end

  defp where_pending(query, options) when is_list(options) do
    pending = Keyword.get(options, :pending)

    case pending do
      false ->
        from(transaction in query, where: not is_nil(transaction.block_hash))

      true ->
        from(transaction in query, where: is_nil(transaction.block_hash))

      nil ->
        query
    end
  end
end
