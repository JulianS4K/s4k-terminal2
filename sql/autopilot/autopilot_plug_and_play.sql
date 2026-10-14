/* =====================================================================
   AUTOPILOT RULE CLASS - PLUG-AND-PLAY SCRIPT  (SQL Server 2016+)

   One self-contained script. Nothing is installed: no tables, views or
   procedures are created. Edit the four marked sections, run it, read
   the results. It only changes data when @Apply = 1.

     SECTION 1  Settings          which event, caps, preview vs apply
     SECTION 2  Rule grid         one line per row on the AutoPilot screen
     SECTION 3  Inventory source  your ticket table and column names
     SECTION 6  Apply             your table/column names for the update

   Sections 4 and 5 are the engine and the reports; no edits needed.
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;


/* =====================================================================
   SECTION 1 - SETTINGS                                     <<< EDIT >>>
   ===================================================================== */
DECLARE @ClassName           VARCHAR(100)     = 'NCAAF - Tulane OD Pilot';
DECLARE @EventId             UNIQUEIDENTIFIER = '20d4b3b4-1ddd-4985-ada9-61b7999c1064';  -- NULL = every event in SECTION 3
DECLARE @PickOrder           VARCHAR(20)      = 'BestRow';  -- BestRow | LowestPrice | HighestPrice | LargestQty
DECLARE @MaxListingsPerEvent INT              = NULL;       -- whole-class listing cap per event (NULL = none)
DECLARE @MaxTicketsPerEvent  INT              = NULL;       -- whole-class ticket cap per event  (NULL = none)
DECLARE @Apply               BIT              = 0;          -- 0 = preview only, 1 = write broadcast flags


/* =====================================================================
   SECTION 2 - RULE GRID                                    <<< EDIT >>>

   One VALUES line per row on the AutoPilot Rule Class screen.
   Use NULL for any blank cell.

   SortOrder    Grid order. A listing belongs to the FIRST line it matches.
   SectionFrom  Comma list. Items can be exact ('FLOORN'), numeric ranges
                ('101-125') or wildcards ('FLOOR*'). NULL = any section.
   SectionTo    If filled in, SectionFrom..SectionTo is one range instead.
   RowFrom/To   Numbers ('1','15'), letters ('A','Z') or doubled letters
                ('AA','MM'). Doubled letters sort after Z.
   PriceFrom/To Sell-price band.
   MinQty/MaxQty  Listing quantity limits. The screen's '{Quantity}>1'
                  is MinQty = 2; '{Quantity}>0' is MinQty = 1.
   BroadcastListings  Max listings this line broadcasts, per event.
   BroadcastTickets   Max tickets (sum of Quantity) this line broadcasts,
                      per event. NULL = no ticket cap.
   ===================================================================== */
DECLARE @Grid TABLE (
    SortOrder          INT           NOT NULL PRIMARY KEY,
    Color              VARCHAR(20)   NULL,
    SectionFrom        VARCHAR(1000) NULL,
    SectionTo          VARCHAR(50)   NULL,
    RowFrom            VARCHAR(10)   NULL,
    RowTo              VARCHAR(10)   NULL,
    PriceFrom          DECIMAL(12,2) NULL,
    PriceTo            DECIMAL(12,2) NULL,
    MinQty             INT           NULL,
    MaxQty             INT           NULL,
    BroadcastListings  INT           NOT NULL,
    BroadcastTickets   INT           NULL
);

INSERT @Grid
 (SortOrder, Color,    SectionFrom,                    SectionTo, RowFrom, RowTo, PriceFrom, PriceTo, MinQty, MaxQty, BroadcastListings, BroadcastTickets)
VALUES
 (1,         'Pink',   '101-103',                      NULL,      'A',     'H',   50,        1000,    2,      NULL,   2,                 12),
 (2,         'Pink',   '101-103',                      NULL,      'I',     'P',   50,        1000,    2,      NULL,   1,                 8),
 (3,         'Pink',   '101-103',                      NULL,      'Q',     'Z',   50,        1000,    2,      NULL,   1,                 8),
 (4,         'Green',  '203-208',                      NULL,      'A',     'E',   50,        1000,    2,      NULL,   1,                 8),
 (5,         'Green',  '203-208',                      NULL,      'F',     'J',   50,        1000,    2,      NULL,   1,                 8),
 (6,         'Green',  '203-208',                      NULL,      'K',     'N',   50,        1000,    2,      NULL,   1,                 8),
 (7,         'Blue',   '120-122, 201, 202, 210, 211',  NULL,      'A',     'Z',   40,        1000,    2,      NULL,   2,                 12),
 (8,         'Orange', '115-119, 123-125',             NULL,      'A',     'Z',   25,        1000,    2,      NULL,   2,                 12),
 (9,         'Orange', '115-119, 123-125',             NULL,      'AA',    'MM',  25,        1000,    2,      NULL,   1,                 8);

/* More examples - copy a line into the VALUES list above:
 -- Simple price floor (">$100" class):
 (1, 'Cyan',   NULL,                             NULL, NULL, NULL, 100, 15000, NULL, NULL, 300, NULL),
 -- Arena, numeric rows, Section From as a list (Magic-style):
 (1, 'Pink',   '103, 108, 112, 117',             NULL, '1',  '2',  175, 1000,  1,    NULL, 2,   NULL),
 (2, 'Pink',   '103, 108, 112, 117',             NULL, '3',  '5',  175, 1000,  2,    NULL, 1,   NULL),
 -- Wildcard sections, pairs to 8-packs only:
 (3, 'Orange', 'FLOOR*',                         NULL, NULL, NULL, 175, 5000,  2,    8,    3,   20),
 -- Section range using SectionFrom/SectionTo:
 (4, 'Green',  '101',                            '125', NULL, NULL, 50, 1000,  2,    NULL, 10,  40),
*/


/* =====================================================================
   SECTION 3 - INVENTORY SOURCE                             <<< EDIT >>>
   Map your ticket-group table and column names on the RIGHT-hand side.
   ===================================================================== */
DROP TABLE IF EXISTS #Inv;

SELECT
    TicketGroupId = tg.TicketGroupId,      -- unique listing id
    EventId       = tg.EventId,
    EventName     = tg.EventName,
    Section       = UPPER(LTRIM(RTRIM(tg.Section))),
    RowLabel      = UPPER(LTRIM(RTRIM(tg.[Row]))),
    Quantity      = tg.Quantity,
    SellPrice     = tg.SellPrice,
    IsBroadcast   = tg.Broadcast
INTO #Inv
FROM dbo.TicketGroup tg                                   -- your table
WHERE tg.TicketStatus NOT IN ('Sold', 'Deleted', 'Void')  -- active inventory only
  AND tg.Quantity > 0
  AND tg.EventDate > GETDATE()                            -- future events only
  AND (@EventId IS NULL OR tg.EventId = @EventId);


/* =====================================================================
   SECTION 4 - ENGINE  (no edits needed)
   ===================================================================== */
DROP TABLE IF EXISTS #Rules, #Picks;

-- Clean up the grid and turn row labels into numbers:
-- '7' -> 7, 'A' -> 1 .. 'Z' -> 26, 'AA' -> 27 .. 'ZZ' -> 52
SELECT g.SortOrder, g.Color,
       SectionFrom = NULLIF(UPPER(LTRIM(RTRIM(g.SectionFrom))), ''),
       SectionTo   = NULLIF(UPPER(LTRIM(RTRIM(g.SectionTo))), ''),
       RowFrom = f.v, RowTo = t.v, g.PriceFrom, g.PriceTo, g.MinQty, g.MaxQty,
       g.BroadcastListings, g.BroadcastTickets,
       RowFromN = CASE WHEN TRY_CAST(f.v AS INT) IS NOT NULL THEN TRY_CAST(f.v AS INT)
                       WHEN f.v LIKE '[A-Z]' THEN ASCII(f.v) - 64
                       WHEN f.v LIKE '[A-Z][A-Z]' AND LEFT(f.v,1) = RIGHT(f.v,1) THEN 26 + ASCII(LEFT(f.v,1)) - 64 END,
       RowToN   = CASE WHEN TRY_CAST(t.v AS INT) IS NOT NULL THEN TRY_CAST(t.v AS INT)
                       WHEN t.v LIKE '[A-Z]' THEN ASCII(t.v) - 64
                       WHEN t.v LIKE '[A-Z][A-Z]' AND LEFT(t.v,1) = RIGHT(t.v,1) THEN 26 + ASCII(LEFT(t.v,1)) - 64 END
INTO   #Rules
FROM   @Grid g
CROSS  APPLY (SELECT v = NULLIF(UPPER(LTRIM(RTRIM(g.RowFrom))), '')) f
CROSS  APPLY (SELECT v = NULLIF(UPPER(LTRIM(RTRIM(g.RowTo))), '')) t;

WITH Inv AS (
    SELECT i.*,
           RowN = CASE WHEN TRY_CAST(i.RowLabel AS INT) IS NOT NULL THEN TRY_CAST(i.RowLabel AS INT)
                       WHEN i.RowLabel LIKE '[A-Z]' THEN ASCII(i.RowLabel) - 64
                       WHEN i.RowLabel LIKE '[A-Z][A-Z]' AND LEFT(i.RowLabel,1) = RIGHT(i.RowLabel,1)
                            THEN 26 + ASCII(LEFT(i.RowLabel,1)) - 64 END
    FROM #Inv i
),
Hits AS (                       -- every listing x grid-line match
    SELECT i.*, r.SortOrder, r.Color, r.BroadcastListings, r.BroadcastTickets,
           FirstRule = ROW_NUMBER() OVER (PARTITION BY i.TicketGroupId ORDER BY r.SortOrder)
    FROM   Inv i
    JOIN   #Rules r
      ON  (   r.SectionFrom IS NULL
           -- SectionFrom..SectionTo range (numeric if both ends are numbers)
           OR (r.SectionTo IS NOT NULL AND (
                  (TRY_CAST(r.SectionFrom AS INT) IS NOT NULL AND TRY_CAST(r.SectionTo AS INT) IS NOT NULL
                   AND TRY_CAST(i.Section AS INT) BETWEEN TRY_CAST(r.SectionFrom AS INT) AND TRY_CAST(r.SectionTo AS INT))
               OR ((TRY_CAST(r.SectionFrom AS INT) IS NULL OR TRY_CAST(r.SectionTo AS INT) IS NULL)
                   AND i.Section BETWEEN r.SectionFrom AND r.SectionTo)))
           -- comma list of exact names, numeric ranges and wildcards
           OR (r.SectionTo IS NULL AND EXISTS (
                  SELECT 1
                  FROM   STRING_SPLIT(r.SectionFrom, ',') s
                  CROSS  APPLY (SELECT Item = LTRIM(RTRIM(s.value))) a
                  CROSS  APPLY (SELECT Dash = CHARINDEX('-', a.Item)) d
                  WHERE  a.Item = i.Section
                     OR (a.Item LIKE '%*%' AND i.Section LIKE REPLACE(a.Item, '*', '%'))
                     OR (d.Dash > 1
                         AND TRY_CAST(i.Section AS INT)
                             BETWEEN TRY_CAST(LEFT(a.Item, d.Dash - 1) AS INT)
                                 AND TRY_CAST(SUBSTRING(a.Item, d.Dash + 1, 50) AS INT)))) )
     AND (r.RowFromN  IS NULL OR i.RowN >= r.RowFromN)
     AND (r.RowToN    IS NULL OR i.RowN <= r.RowToN)
     AND (r.RowFrom   IS NULL OR r.RowFromN IS NOT NULL)   -- unreadable row bound = no match
     AND (r.RowTo     IS NULL OR r.RowToN   IS NOT NULL)
     AND (r.PriceFrom IS NULL OR i.SellPrice >= r.PriceFrom)
     AND (r.PriceTo   IS NULL OR i.SellPrice <= r.PriceTo)
     AND (r.MinQty    IS NULL OR i.Quantity  >= r.MinQty)
     AND (r.MaxQty    IS NULL OR i.Quantity  <= r.MaxQty)
),
Ordered AS (                    -- one line per listing, ranked within its line
    SELECT h.*,
           Pick = ROW_NUMBER() OVER (
               PARTITION BY h.EventId, h.SortOrder
               ORDER BY CASE WHEN @PickOrder = 'LowestPrice'  THEN h.SellPrice END ASC,
                        CASE WHEN @PickOrder = 'HighestPrice' THEN h.SellPrice END DESC,
                        CASE WHEN @PickOrder = 'LargestQty'   THEN h.Quantity  END DESC,
                        h.RowN, h.SellPrice, h.Quantity DESC, h.TicketGroupId)
    FROM   Hits h
    WHERE  h.FirstRule = 1
),
LineCapped AS (                 -- per-line listing and ticket caps
    SELECT o.*,
           LineTickets = SUM(o.Quantity) OVER (PARTITION BY o.EventId, o.SortOrder
                                               ORDER BY o.Pick ROWS UNBOUNDED PRECEDING)
    FROM   Ordered o
),
LineKept AS (
    SELECT * FROM LineCapped
    WHERE  Pick <= BroadcastListings
      AND  (BroadcastTickets IS NULL OR LineTickets <= BroadcastTickets)
),
ClassCapped AS (                -- whole-class caps per event, earlier lines first
    SELECT k.*,
           ClassPick    = ROW_NUMBER() OVER (PARTITION BY k.EventId ORDER BY k.SortOrder, k.Pick),
           ClassTickets = SUM(k.Quantity) OVER (PARTITION BY k.EventId
                                                ORDER BY k.SortOrder, k.Pick ROWS UNBOUNDED PRECEDING)
    FROM   LineKept k
)
SELECT TicketGroupId, EventId, EventName, SortOrder, Color, Section, RowLabel AS [Row],
       Quantity, SellPrice, IsBroadcast, Pick
INTO   #Picks
FROM   ClassCapped
WHERE  (@MaxListingsPerEvent IS NULL OR ClassPick    <= @MaxListingsPerEvent)
  AND  (@MaxTicketsPerEvent  IS NULL OR ClassTickets <= @MaxTicketsPerEvent);


/* =====================================================================
   SECTION 5 - RESULTS  (no edits needed)
   ===================================================================== */
-- 1) Every listing the class broadcasts
SELECT EventName, Line = SortOrder, Color, Section, [Row], Quantity, SellPrice,
       AlreadyBroadcast = IsBroadcast, TicketGroupId
FROM   #Picks
ORDER  BY EventName, SortOrder, Pick;

-- 2) Each grid line: what it picked vs its caps (0 = line matched nothing)
SELECT Line = r.SortOrder, r.Color, r.SectionFrom, r.SectionTo, r.RowFrom, r.RowTo,
       r.PriceFrom, r.PriceTo, r.MinQty, r.MaxQty,
       r.BroadcastListings, PickedListings = COUNT(p.TicketGroupId),
       r.BroadcastTickets,  PickedTickets  = ISNULL(SUM(p.Quantity), 0)
FROM   #Rules r
LEFT   JOIN #Picks p ON p.SortOrder = r.SortOrder
GROUP  BY r.SortOrder, r.Color, r.SectionFrom, r.SectionTo, r.RowFrom, r.RowTo,
          r.PriceFrom, r.PriceTo, r.MinQty, r.MaxQty, r.BroadcastListings, r.BroadcastTickets
ORDER  BY r.SortOrder;

-- 3) Totals
SELECT ClassName = @ClassName,
       Mode      = CASE WHEN @Apply = 1 THEN 'APPLY' ELSE 'PREVIEW ONLY' END,
       Events    = COUNT(DISTINCT EventId),
       Listings  = COUNT(*),
       Tickets   = ISNULL(SUM(Quantity), 0),
       ListValue = ISNULL(SUM(Quantity * SellPrice), 0)
FROM   #Picks;


/* =====================================================================
   SECTION 6 - APPLY                                        <<< EDIT >>>
   Runs only when @Apply = 1. Map the table and columns to your POS.
   If Broadcast is stored as text, use 'Checked' instead of 1.
   ===================================================================== */
IF @Apply = 1
BEGIN
    BEGIN TRAN;

    UPDATE tg
    SET    tg.Broadcast      = 1,              -- your broadcast flag
           tg.IsAutoPilot    = 1,              -- your autopilot flag
           tg.AutoPilot      = @ClassName,     -- your autopilot class column
           tg.DateUpdatedUtc = SYSUTCDATETIME()
    FROM   dbo.TicketGroup tg                  -- your table
    JOIN   #Picks p ON p.TicketGroupId = tg.TicketGroupId;

    PRINT CONCAT('Broadcast flag set on ', @@ROWCOUNT, ' listings for class ', @ClassName, '.');

    COMMIT TRAN;
END
ELSE
    PRINT 'Preview only. Set @Apply = 1 in SECTION 1 to write the changes.';

DROP TABLE IF EXISTS #Inv, #Rules, #Picks;
