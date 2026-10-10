-- Dedicated AzureSql integration fixture for the approved sda-fusion database.
-- Provisioning uses an identity with DDL rights; the live test identity must be restricted.
-- The live test identity must not execute this script.
:setvar ApprovedDatabase "sda-fusion"
:setvar DedicatedSchema "test_sda_azure_sql_it_adapter"

IF DB_NAME() <> N'$(ApprovedDatabase)'
    THROW 51000, 'Connected database is not the approved integration database.', 1;
IF N'$(DedicatedSchema)' NOT LIKE N'test[_]sda[_]azure[_]sql[_]it[_]%'
   OR PATINDEX(N'%[^A-Za-z0-9_]%', N'$(DedicatedSchema)') > 0
    THROW 51001, 'Dedicated schema name is invalid.', 1;
IF SCHEMA_ID(N'$(DedicatedSchema)') IS NOT NULL
    THROW 51002, 'Schema already exists; inspect and reuse or revise this template.', 1;
GO

CREATE SCHEMA [$(DedicatedSchema)];
GO

CREATE TABLE [$(DedicatedSchema)].[AzureSqlAdapterFixture] (
    [RunId] uniqueidentifier NOT NULL,
    [Id] int NULL,
    [Name] nvarchar(max) NULL,
    [Kind] nvarchar(16) NOT NULL,
    [Document] nvarchar(max) NULL
);
GO

CREATE INDEX [IX_AzureSqlAdapterFixture_RunId]
    ON [$(DedicatedSchema)].[AzureSqlAdapterFixture] ([RunId]);
GO

CREATE PROCEDURE [$(DedicatedSchema)].[usp_IngestAzureSqlAdapterFixture]
    @Payload nvarchar(max),
    @RunId uniqueidentifier,
    @Kind nvarchar(16)
AS
BEGIN
    SET NOCOUNT ON;
    IF @RunId IS NULL OR ISJSON(@Payload) <> 1
        THROW 51003, 'Invalid fixture input.', 1;

    IF @Kind = N'Records'
    BEGIN
        IF LEFT(LTRIM(@Payload), 1) <> N'['
            THROW 51004, 'Records payload must be an array.', 1;
        INSERT INTO [$(DedicatedSchema)].[AzureSqlAdapterFixture]
            ([RunId], [Id], [Name], [Kind], [Document])
        SELECT @RunId, CONVERT(int, j.[Id]), j.[Name], N'Records', NULL
        FROM OPENJSON(@Payload)
        WITH ([Id] nvarchar(32) '$.Id', [Name] nvarchar(max) '$.Name') AS j;
        RETURN;
    END;

    IF @Kind = N'Document'
    BEGIN
        INSERT INTO [$(DedicatedSchema)].[AzureSqlAdapterFixture]
            ([RunId], [Id], [Name], [Kind], [Document])
        VALUES (@RunId, NULL, NULL, N'Document', @Payload);
        RETURN;
    END;

    THROW 51005, 'Unsupported fixture kind.', 1;
END;
GO

-- Grant the test principal only SELECT and DELETE on this table,
-- EXECUTE on this procedure, plus minimum schema visibility. Object-scoped
-- VIEW DEFINITION permits direct fixture review by the live test identity;
-- otherwise provide current provisioning-owner evidence.
-- Review effective permissions and absence of triggers before enabling the suite.
