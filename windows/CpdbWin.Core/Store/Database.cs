using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

public static class Database
{
    public static SqliteConnection Open(string path)
    {
        var csb = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
        };
        var conn = new SqliteConnection(csb.ToString());
        conn.Open();
        ApplyPragmas(conn);
        return conn;
    }

    public static bool IsInitialized(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT name FROM sqlite_master WHERE type='table' AND name='entries' LIMIT 1";
        return cmd.ExecuteScalar() is not null;
    }

    private static void ApplyPragmas(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            PRAGMA busy_timeout = 5000;
            """;
        cmd.ExecuteNonQuery();
    }
}
