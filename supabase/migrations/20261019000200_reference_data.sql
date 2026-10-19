-- =====================================================================
-- BEM Ledger — reference data: settings row, chart of accounts, core funds.
-- Uses fixed ids so it can be re-run safely and other scripts can refer
-- to these rows. Edit names freely in the app; codes are what matter.
-- =====================================================================

insert into settings (id) values (1) on conflict (id) do nothing;

insert into accounts (id, code, name, type, subtype, functional_class, is_system, sort, description) values
 ('a0000000-0000-0000-0000-000000001000','1000','Operating Checking','asset','bank',null,true,10,'The ministry''s main bank account. All funds share this account.'),
 ('a0000000-0000-0000-0000-000000001050','1050','Undeposited Gifts','asset','undeposited',null,true,20,'Gifts received but not yet deposited at the bank.'),
 ('a0000000-0000-0000-0000-000000003000','3000','Opening Net Assets - Without Donor Restrictions','net_assets','opening_without',null,true,300,'Used for opening balances only.'),
 ('a0000000-0000-0000-0000-000000003100','3100','Opening Net Assets - With Donor Restrictions','net_assets','opening_with',null,true,310,'Used for opening balances only.'),
 ('a0000000-0000-0000-0000-000000003910','3910','Interfund - Administrative Fees','net_assets','interfund_fee',null,true,391,'Automatic 10% fee moved from missionary funds to the General Fund. Nets to zero organization-wide.'),
 ('a0000000-0000-0000-0000-000000003920','3920','Interfund - Transfers','net_assets','interfund_transfer',null,true,392,'Manual transfers between funds. Nets to zero organization-wide.'),
 ('a0000000-0000-0000-0000-000000004000','4000','Contributions - Individuals','revenue','contribution_individual',null,true,400,null),
 ('a0000000-0000-0000-0000-000000004010','4010','Contributions - Churches & Organizations','revenue','contribution_organization',null,true,401,null),
 ('a0000000-0000-0000-0000-000000004100','4100','Program Service Revenue','revenue','program_revenue',null,false,410,'Fees received for ministry services.'),
 ('a0000000-0000-0000-0000-000000004500','4500','Interest Income','revenue','other_revenue',null,false,450,null),
 ('a0000000-0000-0000-0000-000000004900','4900','Other Income','revenue','other_revenue',null,false,490,null),
 ('a0000000-0000-0000-0000-000000005000','5000','Missionary Support - Salary','expense','expense','program',false,500,null),
 ('a0000000-0000-0000-0000-000000005010','5010','Missionary Support - Housing Allowance','expense','expense','program',false,501,'Ministers'' housing allowance, as designated by the board.'),
 ('a0000000-0000-0000-0000-000000005020','5020','Payroll Taxes & Benefits','expense','expense','program',false,502,null),
 ('a0000000-0000-0000-0000-000000005100','5100','Missionary Ministry Expenses','expense','expense','program',false,510,'Reimbursed ministry expenses (receipts on file).'),
 ('a0000000-0000-0000-0000-000000005150','5150','Ministry Travel','expense','expense','program',false,515,null),
 ('a0000000-0000-0000-0000-000000005200','5200','Conference Expenses','expense','expense','program',false,520,null),
 ('a0000000-0000-0000-0000-000000005300','5300','Church & Pastor Assistance','expense','expense','program',false,530,'Grants such as The Triage Fund.'),
 ('a0000000-0000-0000-0000-000000006000','6000','Office & Administrative','expense','expense','management_general',false,600,null),
 ('a0000000-0000-0000-0000-000000006010','6010','Bank & Payment Processing Fees','expense','expense','management_general',false,601,null),
 ('a0000000-0000-0000-0000-000000006020','6020','Accounting & Legal','expense','expense','management_general',false,602,null),
 ('a0000000-0000-0000-0000-000000006030','6030','Insurance','expense','expense','management_general',false,603,null),
 ('a0000000-0000-0000-0000-000000006040','6040','Technology & Software','expense','expense','management_general',false,604,null),
 ('a0000000-0000-0000-0000-000000006050','6050','Postage & Printing','expense','expense','management_general',false,605,null),
 ('a0000000-0000-0000-0000-000000006500','6500','Fundraising & Donor Communications','expense','expense','fundraising',false,650,null),
 ('a0000000-0000-0000-0000-000000006900','6900','Other Expenses','expense','expense','management_general',false,690,null)
on conflict (id) do nothing;

insert into funds (id, code, name, kind, restriction, admin_fee_applies, is_system, sort, description) values
 ('f0000000-0000-0000-0000-000000000001','GEN','General Fund','general','without',false,true,1,'Unrestricted operating fund. Receives missionary administrative fees.'),
 ('f0000000-0000-0000-0000-000000000002','CONF','Conference Fund','conference','with',false,true,2,'Gifts designated for the Small Church Enrichment Conferences.')
on conflict (id) do nothing;

update settings set admin_fee_fund_id = 'f0000000-0000-0000-0000-000000000001'
 where id = 1 and admin_fee_fund_id is null;
