/* =====================================================================
   AutoPilot Rule Engine  (SQL Server 2016+)

   General-purpose version of the POS "AutoPilot Rule Class Maintenance"
   screen. Works for any venue, event, or rule class.

   Install once:  run this whole file (it is re-runnable).
   Then:          see autopilot_examples.sql for creating classes,
                  testing them, and applying them.

   THE ONLY PART YOU MUST EDIT is section 1, the inventory view.
   Map it to your real ticket-group table and columns.
   ===================================================================== */


/* =====================================================================
   1. INVENTORY ADAPTER  <<< EDIT THIS VIEW TO MATCH YOUR POS SCHEMA >>>

   Every other object reads and writes inventory only through this view.
   Keep it a plain single-table SELECT with direct column aliases so it
   stays updatable (the Apply procedure updates IsBroadcast, IsAutoPilot,
   AutoPilotClass and DateUpdatedUtc through it). If a column is stored
   differently in your POS (for example Broadcast as 'Checked'/'Unchecked'
   text), point the procedure in section 4 at the base table instead.
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_AutoPilotInventory
AS
SELECT
    tg.TicketGroupId      AS TicketGroupId,     -- unique listing id
    tg.EventId            AS EventId,           -- UNIQUEIDENTIFIER
    tg.EventName          AS EventName,
    tg.EventDate          AS EventDate,         -- local event start
    tg.Section            AS Section,
    tg.[Row]              AS [Row],
    tg.Quantity           AS Quantity,
    tg.SellPrice          AS SellPrice,
    tg.PurchasePrice      AS Cost,              -- per-ticket cost
    tg.TicketStatus       AS TicketStatus,
    tg.Broadcast          AS IsBroadcast,       -- BIT
    tg.IsAutoPilot        AS IsAutoPilot,       -- BIT
    tg.AutoPilot          AS AutoPilotClass,    -- class name on the listing
    tg.DateUpdatedUtc     AS DateUpdatedUtc
FROM dbo.TicketGroup tg
WHERE tg.TicketStatus NOT IN ('Sold', 'Deleted', 'Void');  -- active inventory only
GO


/* =====================================================================
   2. TABLES
   ===================================================================== */

/* If you ran the earlier one-off test scripts, drop their tables first:
DROP TABLE IF EXISTS dbo.AutoPilotRule;
DROP TABLE IF EXISTS dbo.AutoPilotClassEvent;
DROP TABLE IF EXISTS dbo.AutoPilotRuleClass;
*/

IF OBJECT_ID('dbo.AutoPilotRuleClass') IS NULL
CREATE TABLE dbo.AutoPilotRuleClass (
    RuleClassId  INT IDENTITY PRIMARY KEY,
    Name         VARCHAR(100) NOT NULL UNIQUE,
    Description  VARCHAR(400) NULL,
    IsActive     BIT          NOT NULL DEFAULT 1,
    -- How to choose which listings fill a row's Broadcast Listings cap:
    --   BestRow (default) | LowestPrice | HighestPrice | LargestQty
    PickOrder    VARCHAR(20)  NOT NULL DEFAULT 'BestRow'
        CHECK (PickOrder IN ('BestRow','LowestPrice','HighestPrice','LargestQty')),
    -- Optional whole-class caps, per event, applied after the row caps
    -- (rows are filled in SortOrder, so earlier rows get priority):
    MaxListingsPerEvent INT NULL CHECK (MaxListingsPerEvent >= 0),
    MaxTicketsPerEvent  INT NULL CHECK (MaxTicketsPerEvent  >= 0),
    CreatedUtc   DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME()
);

/* One row per line in the rule grid. */
IF OBJECT_ID('dbo.AutoPilotRule') IS NULL
CREATE TABLE dbo.AutoPilotRule (
    RuleId             INT IDENTITY PRIMARY KEY,
    RuleClassId        INT NOT NULL REFERENCES dbo.AutoPilotRuleClass(RuleClassId) ON DELETE CASCADE,
    SortOrder          INT NOT NULL,          -- grid order; a listing belongs to the FIRST row it matches
    Color              VARCHAR(20)   NULL,
    -- Section From: comma list. Items can be exact ('FLOORN'), numeric
    -- ranges ('101-125') or wildcards ('FLOOR*', '1*'). If Section To is
    -- filled in, Section From/To are treated as one range instead.
    SectionFrom        VARCHAR(1000) NULL,
    SectionTo          VARCHAR(50)   NULL,
    RowFrom            VARCHAR(10)   NULL,    -- numeric, A-Z, or AA-ZZ
    RowTo              VARCHAR(10)   NULL,
    PriceFrom          DECIMAL(12,2) NULL,
    PriceTo            DECIMAL(12,2) NULL,
    SourceQty          INT           NULL,    -- minimum listing quantity
    -- Rules: conditions joined by AND, e.g. '{Quantity}>1 AND {Margin}>=10'
    -- Fields: Quantity, Price, Cost, Margin, MarginPct, DaysOut, Row
    -- Operators: >  >=  <  <=  =  <>  !=
    Rules              VARCHAR(400)  NULL,
    BroadcastListings  INT           NOT NULL CHECK (BroadcastListings >= 0),  -- listing cap per event
    BroadcastTickets   INT           NULL     CHECK (BroadcastTickets  >= 0),  -- ticket (qty) cap per event; NULL = no cap
    CONSTRAINT UQ_AutoPilotRule_Sort UNIQUE (RuleClassId, SortOrder)
);

/* Which events a class runs on (used when no single event is passed). */
IF OBJECT_ID('dbo.AutoPilotClassEvent') IS NULL
CREATE TABLE dbo.AutoPilotClassEvent (
    RuleClassId  INT              NOT NULL REFERENCES dbo.AutoPilotRuleClass(RuleClassId) ON DELETE CASCADE,
    EventId      UNIQUEIDENTIFIER NOT NULL,
    PRIMARY KEY (RuleClassId, EventId)
);

/* Add the cap columns if the tables came from an earlier version. */
IF COL_LENGTH('dbo.AutoPilotRuleClass', 'MaxListingsPerEvent') IS NULL
    ALTER TABLE dbo.AutoPilotRuleClass ADD MaxListingsPerEvent INT NULL;
IF COL_LENGTH('dbo.AutoPilotRuleClass', 'MaxTicketsPerEvent') IS NULL
    ALTER TABLE dbo.AutoPilotRuleClass ADD MaxTicketsPerEvent INT NULL;
IF COL_LENGTH('dbo.AutoPilotRule', 'BroadcastTickets') IS NULL
    ALTER TABLE dbo.AutoPilotRule ADD BroadcastTickets INT NULL;

/* Audit of every committed broadcast / unbroadcast. */
IF OBJECT_ID('dbo.AutoPilotRunLog') IS NULL
CREATE TABLE dbo.AutoPilotRunLog (
    LogId          BIGINT IDENTITY PRIMARY KEY,
    RunId          UNIQUEIDENTIFIER NOT NULL,
    RunUtc         DATETIME2        NOT NULL DEFAULT SYSUTCDATETIME(),
    ClassName      VARCHAR(100)     NOT NULL,
    EventId        UNIQUEIDENTIFIER NULL,
    TicketGroupId  UNIQUEIDENTIFIER NOT NULL,
    RuleId         INT              NULL,
    Action         VARCHAR(20)      NOT NULL,   -- BROADCAST | UNBROADCAST
    Section        VARCHAR(50)      NULL,
    [Row]          VARCHAR(10)      NULL,
    Quantity       INT              NULL,
    SellPrice      DECIMAL(12,2)    NULL
);
GO


/* =====================================================================
   3. HELPER FUNCTIONS
   ===================================================================== */

/* Row -> sortable number:  '7'->7,  'A'->1..'Z'->26,  'AA'->27..'ZZ'->52.
   Returns NULL for anything else, which never matches a row range. */
CREATE OR ALTER FUNCTION dbo.fn_AutoPilot_RowOrdinal (@r VARCHAR(10))
RETURNS INT
AS
BEGIN
    SET @r = UPPER(LTRIM(RTRIM(@r)));
    IF @r IS NULL OR @r = '' RETURN NULL;
    IF TRY_CAST(@r AS INT) IS NOT NULL RETURN TRY_CAST(@r AS INT);
    IF @r LIKE '[A-Z]' RETURN ASCII(@r) - 64;
    IF @r LIKE '[A-Z][A-Z]' AND LEFT(@r, 1) = RIGHT(@r, 1)
        RETURN 26 + ASCII(LEFT(@r, 1)) - 64;
    RETURN NULL;
END;
GO

/* 1 if @Section matches the rule's Section From / Section To. */
CREATE OR ALTER FUNCTION dbo.fn_AutoPilot_SectionMatch
    (@SectionFrom VARCHAR(1000), @SectionTo VARCHAR(50), @Section VARCHAR(50))
RETURNS BIT
AS
BEGIN
    SET @SectionFrom = NULLIF(LTRIM(RTRIM(@SectionFrom)), '');
    SET @SectionTo   = NULLIF(LTRIM(RTRIM(@SectionTo)), '');
    SET @Section     = UPPER(LTRIM(RTRIM(@Section)));

    IF @SectionFrom IS NULL RETURN 1;                    -- blank = any section
    IF @Section IS NULL RETURN 0;

    IF @SectionTo IS NOT NULL                            -- From/To range
    BEGIN
        IF TRY_CAST(@SectionFrom AS INT) IS NOT NULL AND TRY_CAST(@SectionTo AS INT) IS NOT NULL
            RETURN CASE WHEN TRY_CAST(@Section AS INT)
                             BETWEEN TRY_CAST(@SectionFrom AS INT) AND TRY_CAST(@SectionTo AS INT)
                        THEN 1 ELSE 0 END;
        RETURN CASE WHEN @Section BETWEEN UPPER(@SectionFrom) AND UPPER(@SectionTo) THEN 1 ELSE 0 END;
    END;

    IF EXISTS (                                          -- comma list
        SELECT 1
        FROM STRING_SPLIT(@SectionFrom, ',') s
        CROSS APPLY (SELECT Item = UPPER(LTRIM(RTRIM(s.value)))) i
        CROSS APPLY (SELECT Dash = CHARINDEX('-', i.Item)) d
        CROSS APPLY (SELECT Lo = CASE WHEN d.Dash > 1 THEN TRY_CAST(LEFT(i.Item, d.Dash - 1) AS INT) END,
                            Hi = CASE WHEN d.Dash > 1 THEN TRY_CAST(SUBSTRING(i.Item, d.Dash + 1, 50) AS INT) END) r
        WHERE i.Item <> ''
          AND (    i.Item = @Section
               OR (i.Item LIKE '%*%' AND @Section LIKE REPLACE(i.Item, '*', '%'))
               OR (r.Lo IS NOT NULL AND r.Hi IS NOT NULL
                   AND TRY_CAST(@Section AS INT) BETWEEN r.Lo AND r.Hi))
    )
        RETURN 1;

    RETURN 0;
END;
GO

/* 1 if a listing passes the Rules column. Blank = pass.
   Unknown fields or unparseable values FAIL, so a typo never broadcasts. */
CREATE OR ALTER FUNCTION dbo.fn_AutoPilot_EvalRules
(
    @Rules    VARCHAR(400),
    @Quantity INT,
    @Price    DECIMAL(12,2),
    @Cost     DECIMAL(12,2),
    @DaysOut  INT,
    @RowN     INT
)
RETURNS BIT
AS
BEGIN
    IF NULLIF(LTRIM(RTRIM(@Rules)), '') IS NULL RETURN 1;

    DECLARE @s VARCHAR(400) =
        REPLACE(REPLACE(REPLACE(UPPER(@Rules), ' AND ', '|'), '&&', '|'), ' ', '');

    IF EXISTS (
        SELECT 1
        FROM STRING_SPLIT(@s, '|') c
        CROSS APPLY (SELECT Clause = c.value,
                            CloseBrace = CHARINDEX('}', c.value)) a
        CROSS APPLY (SELECT Field = CASE WHEN LEFT(a.Clause, 1) = '{' AND a.CloseBrace > 2
                                         THEN SUBSTRING(a.Clause, 2, a.CloseBrace - 2) END,
                            Rest  = SUBSTRING(a.Clause, a.CloseBrace + 1, 400)) b
        CROSS APPLY (SELECT Op = CASE WHEN LEFT(b.Rest, 2) IN ('>=', '<=', '<>', '!=') THEN LEFT(b.Rest, 2)
                                      WHEN LEFT(b.Rest, 1) IN ('>', '<', '=')          THEN LEFT(b.Rest, 1) END) o
        CROSS APPLY (SELECT Rhs = TRY_CAST(SUBSTRING(b.Rest, LEN(o.Op) + 1, 400) AS DECIMAL(18,4))) v
        CROSS APPLY (SELECT Lhs = CAST(CASE b.Field
                                WHEN 'QUANTITY'  THEN @Quantity
                                WHEN 'QTY'       THEN @Quantity
                                WHEN 'PRICE'     THEN @Price
                                WHEN 'SELLPRICE' THEN @Price
                                WHEN 'COST'      THEN @Cost
                                WHEN 'MARGIN'    THEN @Price - @Cost
                                WHEN 'MARGINPCT' THEN (@Price - @Cost) * 100.0 / NULLIF(@Cost, 0)
                                WHEN 'DAYSOUT'   THEN @DaysOut
                                WHEN 'ROW'       THEN @RowN
                            END AS DECIMAL(18,4))) l
        WHERE c.value <> ''
          AND NOT (    o.Op IS NOT NULL AND v.Rhs IS NOT NULL AND l.Lhs IS NOT NULL
                   AND (   (o.Op = '>'  AND l.Lhs >  v.Rhs)
                        OR (o.Op = '>=' AND l.Lhs >= v.Rhs)
                        OR (o.Op = '<'  AND l.Lhs <  v.Rhs)
                        OR (o.Op = '<=' AND l.Lhs <= v.Rhs)
                        OR (o.Op = '='  AND l.Lhs =  v.Rhs)
                        OR (o.Op IN ('<>', '!=') AND l.Lhs <> v.Rhs)))
    )
        RETURN 0;   -- at least one clause failed

    RETURN 1;
END;
GO


/* =====================================================================
   4. ENGINE
   ===================================================================== */

/* What a class WOULD broadcast. Read-only; same as the Test button.
   @EventId = NULL runs every event assigned in AutoPilotClassEvent.

   Logic:
     - each listing is matched against the class's rows in SortOrder;
       it belongs only to the first row it matches
     - each row then keeps its top listings PER EVENT (order = class
       PickOrder) until either cap is hit:
         Broadcast Listings  - number of listings
         Broadcast Tickets   - running total of Quantity (NULL = no cap)
     - finally the class-wide MaxListingsPerEvent / MaxTicketsPerEvent
       caps are applied across all rows, earlier SortOrder first.
     Ticket caps stop at the first listing that would go over the cap;
     a smaller listing further down the order is not used to fill the gap. */
CREATE OR ALTER FUNCTION dbo.fn_AutoPilot_Picks
    (@ClassName VARCHAR(100), @EventId UNIQUEIDENTIFIER)
RETURNS TABLE
AS
RETURN
WITH R AS (
    SELECT r.*, c.PickOrder, c.MaxListingsPerEvent, c.MaxTicketsPerEvent,
           RowFromN = dbo.fn_AutoPilot_RowOrdinal(r.RowFrom),
           RowToN   = dbo.fn_AutoPilot_RowOrdinal(r.RowTo)
    FROM   dbo.AutoPilotRule r
    JOIN   dbo.AutoPilotRuleClass c ON c.RuleClassId = r.RuleClassId
    WHERE  c.Name = @ClassName AND c.IsActive = 1
),
Scope AS (
    SELECT i.*,
           RowN    = dbo.fn_AutoPilot_RowOrdinal(i.[Row]),
           DaysOut = DATEDIFF(DAY, GETDATE(), i.EventDate)
    FROM   dbo.vw_AutoPilotInventory i
    WHERE  i.Quantity > 0
      AND  i.EventDate > GETDATE()
      AND  (   i.EventId = @EventId
            OR (@EventId IS NULL AND EXISTS (
                    SELECT 1
                    FROM dbo.AutoPilotClassEvent ce
                    JOIN dbo.AutoPilotRuleClass c ON c.RuleClassId = ce.RuleClassId
                    WHERE c.Name = @ClassName AND ce.EventId = i.EventId)))
),
Hits AS (
    SELECT s.TicketGroupId, s.EventId, s.EventName, s.Section, s.[Row], s.RowN,
           s.Quantity, s.SellPrice, s.Cost, s.IsBroadcast,
           R.RuleId, R.SortOrder, R.Color, R.BroadcastListings, R.BroadcastTickets, R.PickOrder,
           R.MaxListingsPerEvent, R.MaxTicketsPerEvent,
           FirstRule = ROW_NUMBER() OVER (PARTITION BY s.TicketGroupId ORDER BY R.SortOrder)
    FROM   Scope s
    JOIN   R
      ON   dbo.fn_AutoPilot_SectionMatch(R.SectionFrom, R.SectionTo, s.Section) = 1
     AND  (R.RowFromN  IS NULL OR s.RowN >= R.RowFromN)
     AND  (R.RowToN    IS NULL OR s.RowN <= R.RowToN)
     AND  (R.PriceFrom IS NULL OR s.SellPrice >= R.PriceFrom)
     AND  (R.PriceTo   IS NULL OR s.SellPrice <= R.PriceTo)
     AND  (R.SourceQty IS NULL OR s.Quantity  >= R.SourceQty)
     AND   dbo.fn_AutoPilot_EvalRules(R.Rules, s.Quantity, s.SellPrice, s.Cost, s.DaysOut, s.RowN) = 1
),
Ordered AS (
    SELECT h.*,
           OrderKey = ROW_NUMBER() OVER (
               PARTITION BY h.EventId, h.RuleId
               ORDER BY
                   CASE WHEN h.PickOrder = 'LowestPrice'  THEN h.SellPrice END ASC,
                   CASE WHEN h.PickOrder = 'HighestPrice' THEN h.SellPrice END DESC,
                   CASE WHEN h.PickOrder = 'LargestQty'   THEN h.Quantity  END DESC,
                   h.RowN, h.SellPrice, h.Quantity DESC, h.TicketGroupId)
    FROM   Hits h
    WHERE  h.FirstRule = 1
),
RuleCapped AS (             -- per-row caps: listings and tickets
    SELECT o.*,
           Pick       = o.OrderKey,
           RuleQtyRun = SUM(o.Quantity) OVER (PARTITION BY o.EventId, o.RuleId
                                              ORDER BY o.OrderKey ROWS UNBOUNDED PRECEDING)
    FROM   Ordered o
),
RuleKept AS (
    SELECT *
    FROM   RuleCapped
    WHERE  Pick <= BroadcastListings
      AND  (BroadcastTickets IS NULL OR RuleQtyRun <= BroadcastTickets)
),
ClassCapped AS (            -- class-wide caps per event, earlier rows first
    SELECT k.*,
           ClassPick   = ROW_NUMBER() OVER (PARTITION BY k.EventId ORDER BY k.SortOrder, k.Pick),
           ClassQtyRun = SUM(k.Quantity) OVER (PARTITION BY k.EventId
                                               ORDER BY k.SortOrder, k.Pick ROWS UNBOUNDED PRECEDING)
    FROM   RuleKept k
)
SELECT TicketGroupId, EventId, EventName, RuleId, SortOrder, Color,
       Section, [Row], Quantity, SellPrice, Cost, IsBroadcast, Pick,
       BroadcastListings, BroadcastTickets, RuleQtyRun, ClassQtyRun
FROM   ClassCapped
WHERE  (MaxListingsPerEvent IS NULL OR ClassPick   <= MaxListingsPerEvent)
  AND  (MaxTicketsPerEvent  IS NULL OR ClassQtyRun <= MaxTicketsPerEvent);
GO

/* Test: shows the picks plus summaries. Changes nothing. */
CREATE OR ALTER PROCEDURE dbo.usp_AutoPilot_Test
    @ClassName VARCHAR(100),
    @EventId   UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.AutoPilotRuleClass WHERE Name = @ClassName)
        THROW 50001, 'AutoPilot class not found.', 1;

    SELECT * INTO #Picks FROM dbo.fn_AutoPilot_Picks(@ClassName, @EventId);

    -- 1) every listing that would broadcast
    SELECT EventName, SortOrder, Color, Section, [Row], Quantity, SellPrice, Cost,
           AlreadyBroadcast = IsBroadcast, TicketGroupId
    FROM   #Picks
    ORDER  BY EventName, SortOrder, Pick;

    -- 2) per rule row: filled vs cap (spots a row that matches nothing)
    SELECT e.EventName, r.SortOrder, r.Color, r.SectionFrom, r.RowFrom, r.RowTo,
           r.PriceFrom, r.PriceTo, r.Rules, r.BroadcastListings, r.BroadcastTickets,
           PickedListings = COUNT(p.TicketGroupId),
           PickedTickets  = ISNULL(SUM(p.Quantity), 0)
    FROM   dbo.AutoPilotRule r
    JOIN   dbo.AutoPilotRuleClass c ON c.RuleClassId = r.RuleClassId AND c.Name = @ClassName
    CROSS  JOIN (SELECT DISTINCT EventId, EventName FROM #Picks) e
    LEFT   JOIN #Picks p ON p.RuleId = r.RuleId AND p.EventId = e.EventId
    GROUP  BY e.EventName, r.SortOrder, r.Color, r.SectionFrom, r.RowFrom, r.RowTo,
              r.PriceFrom, r.PriceTo, r.Rules, r.BroadcastListings, r.BroadcastTickets
    ORDER  BY e.EventName, r.SortOrder;

    -- 3) totals
    SELECT Events = COUNT(DISTINCT EventId), Listings = COUNT(*),
           Tickets = SUM(Quantity), ListValue = SUM(Quantity * SellPrice)
    FROM   #Picks;
END;
GO

/* Apply: broadcasts the picks.
   @Commit = 0 (default) is a dry run: it does everything, reports the
   counts, then rolls back. Set @Commit = 1 to keep the changes.
   @UnbroadcastOthers = 1 also turns off listings that this class broadcast
   earlier but that no longer qualify (price moved, sold down, etc.). */
CREATE OR ALTER PROCEDURE dbo.usp_AutoPilot_Apply
    @ClassName          VARCHAR(100),
    @EventId            UNIQUEIDENTIFIER = NULL,
    @Commit             BIT = 0,
    @UnbroadcastOthers  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.AutoPilotRuleClass WHERE Name = @ClassName AND IsActive = 1)
        THROW 50001, 'AutoPilot class not found or inactive.', 1;

    DECLARE @RunId UNIQUEIDENTIFIER = NEWID(),
            @Now   DATETIME2        = SYSUTCDATETIME(),
            @On    INT = 0,
            @Off   INT = 0;

    SELECT * INTO #Picks FROM dbo.fn_AutoPilot_Picks(@ClassName, @EventId);

    BEGIN TRAN;

    -- turn ON
    UPDATE i
    SET    i.IsBroadcast    = 1,
           i.IsAutoPilot    = 1,
           i.AutoPilotClass = @ClassName,
           i.DateUpdatedUtc = @Now
    OUTPUT @RunId, @ClassName, inserted.EventId, inserted.TicketGroupId, p.RuleId, 'BROADCAST',
           inserted.Section, inserted.[Row], inserted.Quantity, inserted.SellPrice
      INTO dbo.AutoPilotRunLog (RunId, ClassName, EventId, TicketGroupId, RuleId, Action,
                                Section, [Row], Quantity, SellPrice)
    FROM   dbo.vw_AutoPilotInventory i
    JOIN   #Picks p ON p.TicketGroupId = i.TicketGroupId
    WHERE  ISNULL(i.IsBroadcast, 0) = 0
       OR  ISNULL(i.AutoPilotClass, '') <> @ClassName;
    SET @On = @@ROWCOUNT;

    -- turn OFF what this class broadcast before but no longer picks
    IF @UnbroadcastOthers = 1
    BEGIN
        UPDATE i
        SET    i.IsBroadcast    = 0,
               i.DateUpdatedUtc = @Now
        OUTPUT @RunId, @ClassName, inserted.EventId, inserted.TicketGroupId, NULL, 'UNBROADCAST',
               inserted.Section, inserted.[Row], inserted.Quantity, inserted.SellPrice
          INTO dbo.AutoPilotRunLog (RunId, ClassName, EventId, TicketGroupId, RuleId, Action,
                                    Section, [Row], Quantity, SellPrice)
        FROM   dbo.vw_AutoPilotInventory i
        WHERE  i.AutoPilotClass = @ClassName
          AND  i.IsBroadcast = 1
          AND  (   i.EventId = @EventId
                OR (@EventId IS NULL AND EXISTS (
                        SELECT 1 FROM dbo.AutoPilotClassEvent ce
                        JOIN dbo.AutoPilotRuleClass c ON c.RuleClassId = ce.RuleClassId
                        WHERE c.Name = @ClassName AND ce.EventId = i.EventId)))
          AND  NOT EXISTS (SELECT 1 FROM #Picks p WHERE p.TicketGroupId = i.TicketGroupId);
        SET @Off = @@ROWCOUNT;
    END;

    SELECT RunId = @RunId,
           Mode = CASE WHEN @Commit = 1 THEN 'COMMITTED' ELSE 'DRY RUN (rolled back)' END,
           Picked = (SELECT COUNT(*) FROM #Picks),
           NewlyBroadcast = @On,
           Unbroadcast = @Off;

    IF @Commit = 1
        COMMIT TRAN;
    ELSE
        ROLLBACK TRAN;
END;
GO
