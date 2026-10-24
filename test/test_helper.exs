Aviary.StubbedServices.point_at_stubs()
ExUnit.start()

Ecto.Migrator.run(Aviary.Repo, :up, all: true)

ExUnit.after_suite(fn _ ->
  path = Application.fetch_env!(:aviary, Aviary.Repo)[:database]
  Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
end)
