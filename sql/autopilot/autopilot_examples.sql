/* =====================================================================
   AutoPilot Rule Engine - examples
   Run autopilot_engine.sql first.

   Pattern for ANY class:
     1. insert the class         (AutoPilotRuleClass)
     2. insert its grid rows     (AutoPilotRule)
     3. assign events            (AutoPilotClassEvent)  - or pass @EventId
     4. EXEC usp_AutoPilot_Test
     5. EXEC usp_AutoPilot_Apply @Commit = 0, check counts, then @Commit = 1
   ===================================================================== */


/* ---------------------------------------------------------------------
   Example A: simple price-floor class (the ">$100" screen)
   --------------------------------------------------------------------- */
DECLARE @Id INT;

INSERT dbo.AutoPilotRuleClass (Name, Description) VALUES ('>$100', 'Over $100');
SET @Id = SCOPE_IDENTITY();

INSERT dbo.AutoPilotRule (RuleClassId, SortOrder, Color, PriceFrom, PriceTo, BroadcastListings)
VALUES (@Id, 1, 'Cyan', 100.00, 15000.00, 300);
GO


/* ---------------------------------------------------------------------
   Example B: NBA - Orlando Magic (the MAGIC RULE screen)
   --------------------------------------------------------------------- */
DECLARE @Id INT;

INSERT dbo.AutoPilotRuleClass (Name, Description) VALUES ('NBA - Orlando Magic', 'MAGIC RULE');
SET @Id = SCOPE_IDENTITY();

INSERT dbo.AutoPilotRule
    (RuleClassId, SortOrder, Color, SectionFrom, RowFrom, RowTo, PriceFrom, PriceTo, Rules, BroadcastListings)
VALUES
(@Id,  1, 'Pink',   '103, 108, 112, 117',                     '1',  '2',  175, 1000, '{Quantity}>0', 2),
(@Id,  2, 'Pink',   '103, 108, 112, 117',                     '3',  '5',  175, 1000, '{Quantity}>1', 1),
(@Id,  3, 'Pink',   '103, 108, 112, 117',                     '6',  '15', 175, 1000, '{Quantity}>1', 1),
(@Id,  4, 'Green',  '113, 114, 115, 116, 107, 106, 105, 104', '5',  '7',  175, 5000, '{Quantity}>1', 1),
(@Id,  5, 'Green',  '113, 114, 115, 116, 107, 106, 105, 104', '8',  '10', 175, 5000, '{Quantity}>1', 1),
(@Id,  6, 'Green',  '113, 114, 115, 116, 107, 106, 105, 104', '11', '15', 175, 5000, '{Quantity}>1', 1),
(@Id,  7, 'Green',  '113, 114, 115, 116, 107, 106, 105, 104', '1',  '2',  175, 5000, '{Quantity}>1', 1),
(@Id,  8, 'Green',  '113, 114, 115, 116, 107, 106, 105, 104', '3',  '5',  175, 5000, '{Quantity}>1', 1),
(@Id,  9, 'Blue',   '101, 102, 109, 110, 111, 118',           '1',  '5',  175, 1000, '{Quantity}>1', 1),
(@Id, 10, 'Orange', 'FLOORN, FLOORS, FLOORW, FLOORE',         NULL, NULL, 175, 5000, '{Quantity}>1', 3),
(@Id, 11, 'Orange', 'FLOORN, FLOORS, FLOORW, FLOORE',         '1',  '2',  175, 5000, '{Quantity}>1', 1),
(@Id, 12, 'Orange', 'FLOORN, FLOORS, FLOORW, FLOORE',         '3',  '5',  175, 5000, '{Quantity}>1', 1);
-- Note: in the screen, row 10 (no row range) comes before rows 11-12, so
-- it claims floor listings in rows 1-5 first. Reorder SortOrder if you
-- want the row-specific lines to win.
GO


/* ---------------------------------------------------------------------
   Example C: open-distribution pilot for a stadium with letter rows
   (Tulane / Yulman). Same structure works for any venue - change the
   section lists, row bands and price floors.
   --------------------------------------------------------------------- */
DECLARE @Id INT;

-- Class-wide caps per event: at most 12 listings and 60 tickets in total.
INSERT dbo.AutoPilotRuleClass (Name, Description, PickOrder, MaxListingsPerEvent, MaxTicketsPerEvent)
VALUES ('NCAAF - Tulane OD Pilot', 'Open distribution test - one small sample per zone', 'BestRow', 12, 60);
SET @Id = SCOPE_IDENTITY();

INSERT dbo.AutoPilotRule
    (RuleClassId, SortOrder, Color, SectionFrom, RowFrom, RowTo, PriceFrom, PriceTo, Rules,
     BroadcastListings, BroadcastTickets)            -- BroadcastTickets = qty cap per row (NULL = none)
VALUES
(@Id, 1, 'Pink',   '101-103',                     'A',  'H',  50, 1000, '{Quantity}>1', 2, 12),
(@Id, 2, 'Pink',   '101-103',                     'I',  'P',  50, 1000, '{Quantity}>1', 1, 8),
(@Id, 3, 'Pink',   '101-103',                     'Q',  'Z',  50, 1000, '{Quantity}>1', 1, 8),
(@Id, 4, 'Green',  '203-208',                     'A',  'E',  50, 1000, '{Quantity}>1', 1, 8),
(@Id, 5, 'Green',  '203-208',                     'F',  'J',  50, 1000, '{Quantity}>1', 1, 8),
(@Id, 6, 'Green',  '203-208',                     'K',  'N',  50, 1000, '{Quantity}>1', 1, 8),
(@Id, 7, 'Blue',   '120-122, 201, 202, 210, 211', 'A',  'Z',  40, 1000, '{Quantity}>1', 2, 12),
(@Id, 8, 'Orange', '115-119, 123-125',            'A',  'Z',  25, 1000, '{Quantity}>1', 2, 12),
(@Id, 9, 'Orange', '115-119, 123-125',            'AA', 'MM', 25, 1000, '{Quantity}>1', 1, 8);

INSERT dbo.AutoPilotClassEvent (RuleClassId, EventId)
VALUES (@Id, '20d4b3b4-1ddd-4985-ada9-61b7999c1064');   -- North Texas at Tulane
GO


/* ---------------------------------------------------------------------
   More Rules-column examples (any row, any class)
   --------------------------------------------------------------------- */
-- '{Quantity}>=2 AND {Quantity}<=8'      pairs through 8-packs only
-- '{MarginPct}>=20'                      only listings at 20%+ over cost
-- '{Margin}>5 AND {DaysOut}<=14'         $5+ profit, within two weeks of the event
-- '{Row}<=10'                            front ten rows (A-J or 1-10)
-- Caps: BroadcastListings = max listings per row per event,
--       BroadcastTickets  = max tickets (sum of Quantity) per row per event,
--       class MaxListingsPerEvent / MaxTicketsPerEvent = totals across all rows.
--   UPDATE dbo.AutoPilotRuleClass SET MaxTicketsPerEvent = 100 WHERE Name = '>$100';
-- Section From examples:  '101-125'   'FLOOR*'   '101, 105-110, CLUB*'


/* ---------------------------------------------------------------------
   Running a class
   --------------------------------------------------------------------- */
-- Test one event (read-only):
EXEC dbo.usp_AutoPilot_Test
     @ClassName = 'NCAAF - Tulane OD Pilot',
     @EventId   = '20d4b3b4-1ddd-4985-ada9-61b7999c1064';

-- Test every event assigned to the class:
EXEC dbo.usp_AutoPilot_Test @ClassName = 'NCAAF - Tulane OD Pilot';

-- Dry run (does the updates, reports counts, rolls back):
EXEC dbo.usp_AutoPilot_Apply @ClassName = 'NCAAF - Tulane OD Pilot';

-- For real:
-- EXEC dbo.usp_AutoPilot_Apply @ClassName = 'NCAAF - Tulane OD Pilot', @Commit = 1;

-- Re-run later and also pull listings that no longer qualify:
-- EXEC dbo.usp_AutoPilot_Apply @ClassName = 'NCAAF - Tulane OD Pilot',
--                              @Commit = 1, @UnbroadcastOthers = 1;

-- What happened:
SELECT TOP 100 * FROM dbo.AutoPilotRunLog ORDER BY LogId DESC;
