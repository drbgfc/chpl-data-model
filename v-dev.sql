--
-- Performance
--
-- Add indexes to improve the retrieval of parent, child listings
DROP INDEX IF EXISTS openchpl.ix_isting_to_listing_map_parent_id_deleted;

CREATE INDEX ix_listing_to_listing_map_parent_id_deleted
    ON openchpl.listing_to_listing_map USING btree
    (parent_listing_id, deleted)
    TABLESPACE pg_default;
	
DROP INDEX IF EXISTS openchpl.ix_listing_to_listing_map_child_id_deleted;

CREATE INDEX ix_listing_to_listing_map_child_id_deleted
    ON openchpl.listing_to_listing_map USING btree
    (child_listing_id, deleted)
    TABLESPACE pg_default;	
	

--
-- OCD-1897 Tables, triggers, and population of tables
--
drop table if exists openchpl.certified_product_testing_lab_map;
create table openchpl.certified_product_testing_lab_map (
   id bigserial not null,
   certified_product_id bigint not null,
   testing_lab_id bigint not null,
   creation_date timestamp without time zone not null default now(),
   last_modified_date timestamp without time zone not null default now(),
   last_modified_user bigint not null,
   deleted boolean not null default false,
        constraint certified_product_testing_lab_map_pk primary key (id),
 constraint certified_product_fk foreign key (certified_product_id)
        references openchpl.certified_product (certified_product_id) match simple
        on update no action on delete no action,
 constraint testing_lab_fk foreign key (testing_lab_id)
        references openchpl.testing_lab (testing_lab_id) match simple
        on update no action on delete no action
);

insert into openchpl.certified_product_testing_lab_map (certified_product_id, testing_lab_id, last_modified_user) select certified_product_id, testing_lab_id, -1 from openchpl.certified_product as cp where cp.testing_lab_id is not null;

create trigger certified_product_testing_lab_map_audit after insert or update or delete on openchpl.certified_product_testing_lab_map for each row execute procedure audit.if_modified_func();
create trigger certified_product_testing_lab_map_timestamp before update on openchpl.certified_product_testing_lab_map for each row execute procedure openchpl.update_last_modified_date_column();

drop table if exists openchpl.pending_certified_product_testing_lab_map;
create table openchpl.pending_certified_product_testing_lab_map (
   id bigserial not null,
   pending_certified_product_id bigint not null,
   testing_lab_id bigint not null,
   testing_lab_name varchar(300),
   creation_date timestamp without time zone not null default now(),
   last_modified_date timestamp without time zone not null default now(),
   last_modified_user bigint not null,
   deleted boolean not null default false,
        constraint pending_certified_product_testing_lab_map_pk primary key (id),
 constraint pending_certified_product_fk foreign key (pending_certified_product_id)
        references openchpl.pending_certified_product (pending_certified_product_id) match simple
        on update no action on delete no action,
 constraint testing_lab_fk foreign key (testing_lab_id)
        references openchpl.testing_lab (testing_lab_id) match simple
        on update no action on delete no action
);

update openchpl.pending_certified_product set deleted = true where testing_lab_name is null or testing_lab_id is null;
insert into openchpl.pending_certified_product_testing_lab_map (pending_certified_product_id, testing_lab_id, testing_lab_name, last_modified_user) select pending_certified_product_id, testing_lab_id, testing_lab_name, -1 from openchpl.pending_certified_product as cp where cp.deleted = false;

create trigger pending_certified_product_testing_lab_map_audit after insert or update or delete on openchpl.pending_certified_product_testing_lab_map for each row execute procedure audit.if_modified_func();
create trigger pending_certified_product_testing_lab_map_timestamp before update on openchpl.pending_certified_product_testing_lab_map for each row execute procedure openchpl.update_last_modified_date_column();

--
-- Questionable activity trigger
--
INSERT INTO openchpl.questionable_activity_trigger (name, level, last_modified_user) select 'Testing Lab Changed', 'Listing', -1 where not exists (select * from openchpl.questionable_activity_trigger where name = 'Testing Lab Changed');

--
-- OCD-2031
--
insert into openchpl.notification_type (name, description, requires_acb, last_modified_user) select 'Cache Status Age Notification', 'A notification that is sent to subscribers when the Listing Cache is too old.', false, -1 where not exists (select * from openchpl.notification_type where name = 'Cache Status Age Notification');
create or replace function openchpl.add_permission() returns void as $$
    begin
    if (select count(*) from openchpl.notification_type_permission where notification_type_id =
	(select id from openchpl.notification_type where name = 'Cache Status Age Notification')) = 0 then
insert into openchpl.notification_type_permission (notification_type_id, permission_id, last_modified_user)
select id, -2, -1 from openchpl.notification_type where name = 'Cache Status Age Notification';
    end if;
    end;
    $$ language plpgsql;
select openchpl.add_permission();
drop function openchpl.add_permission();

--
-- OCD-1897 CHPL Product Number function & Views
--
create or replace function openchpl.get_testing_lab_code(input_id bigint) returns
    table (
        testing_lab_code varchar
        ) as $$
    begin
    return query
        select
            case
            when (select count(*) from openchpl.certified_product_testing_lab_map as a
            where a.certified_product_id = input_id
                and a.deleted = false) = 1
                    then (select b.testing_lab_code from openchpl.testing_lab b, openchpl.certified_product_testing_lab_map c
                        where b.testing_lab_id = c.testing_lab_id
                     and c.certified_product_id = input_id
                            and c.deleted = false)
            when (select count(*) from openchpl.certified_product_testing_lab_map as a
            where a.certified_product_id = input_id
                and a.deleted = false) = 0
            then null
                else '99'
            end;
end;
$$ language plpgsql
stable;

create or replace function openchpl.get_chpl_product_number(id bigint) returns
    table (
        chpl_product_number varchar
        ) as $$
    begin
    return query
        select
            COALESCE(a.chpl_product_number, substring(b.year from 3 for 2)||'.'||(select openchpl.get_testing_lab_code(a.certified_product_id))||'.'||c.certification_body_code||'.'||h.vendor_code||'.'||a.product_code||'.'||a.version_code||'.'||a.ics_code||'.'||a.additional_software_code||'.'||a.certified_date_code) as "chpl_product_number"
                FROM openchpl.certified_product a
                    LEFT JOIN (SELECT certification_edition_id, year FROM openchpl.certification_edition) b on a.certification_edition_id = b.certification_edition_id
                    LEFT JOIN (SELECT certification_body_id, name as "certification_body_name", acb_code as "certification_body_code", deleted as "acb_is_deleted" FROM openchpl.certification_body) c on a.certification_body_id = c.certification_body_id
                    LEFT JOIN (SELECT product_version_id, version as "product_version", product_id from openchpl.product_version) f on a.product_version_id = f.product_version_id
                    LEFT JOIN (SELECT product_id, vendor_id, name as "product_name" FROM openchpl.product) g ON f.product_id = g.product_id
                    LEFT JOIN (SELECT vendor_id, name as "vendor_name", vendor_code, website as "vendor_website", address_id as "vendor_address", contact_id as "vendor_contact", vendor_status_id from openchpl.vendor) h on g.vendor_id = h.vendor_id
                WHERE a.certified_product_id = id;
end;
$$ language plpgsql
stable;

CREATE OR REPLACE FUNCTION openchpl.get_chpl_product_number_as_text(
    id bigint
    )
RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE
AS $BODY$
declare
    cpn text;
BEGIN
    SELECT chpl_product_number into cpn
    FROM openchpl.get_chpl_product_number(id);
    RETURN cpn;
END;
$BODY$;

DROP VIEW IF EXISTS openchpl.certified_product_details CASCADE;

CREATE OR REPLACE VIEW openchpl.certified_product_details AS
SELECT
    a.certified_product_id,
    a.certification_edition_id,
    a.product_version_id,
    a.certification_body_id,
    (select chpl_product_number from openchpl.get_chpl_product_number(a.certified_product_id)),
    a.report_file_location,
    a.sed_report_file_location,
    a.sed_intended_user_description,
    a.sed_testing_end,
    a.acb_certification_id,
    a.practice_type_id,
    a.product_classification_type_id,
    a.other_acb,
    a.creation_date,
    a.deleted,
    a.product_code,
    a.version_code,
    a.ics_code,
    a.additional_software_code,
    a.certified_date_code,
    a.transparency_attestation_url,
    a.ics,
    a.sed,
    a.qms,
    a.accessibility_certified,
    a.product_additional_software,
    a.last_modified_date,
    a.meaningful_use_users,
    b.year,
    c.certification_body_name,
    c.certification_body_code,
    c.acb_is_deleted,
    d.product_classification_name,
    e.practice_type_name,
    f.product_version,
    f.product_id,
    g.product_name,
    g.vendor_id,
    h.vendor_name,
    h.vendor_code,
    h.vendor_website,
    v.vendor_status_id,
    v.vendor_status_name,
    vendorstatus.last_vendor_status_change,
    t.address_id,
    t.street_line_1,
    t.street_line_2,
    t.city,
    t.state,
    t.zipcode,
    t.country,
    u.contact_id,
    u.first_name,
    u.last_name,
    u.email,
    u.phone_number,
    u.title,
    i.certification_date,
    decert.decertification_date,
    COALESCE(k.count_certifications, 0::bigint) AS count_certifications,
    COALESCE(m.count_cqms, 0::bigint) AS count_cqms,
    COALESCE(surv.count_surveillance_activities, 0::bigint) AS count_surveillance_activities,
    COALESCE(surv_open.count_open_surveillance_activities, 0::bigint) AS count_open_surveillance_activities,
    COALESCE(surv_closed.count_closed_surveillance_activities, 0::bigint) AS count_closed_surveillance_activities,
    COALESCE(nc_open.count_open_nonconformities, 0::bigint) AS count_open_nonconformities,
    COALESCE(nc_closed.count_closed_nonconformities, 0::bigint) AS count_closed_nonconformities,
    r.certification_status_id,
    r.last_certification_status_change,
    n.certification_status_name,
    p.transparency_attestation,
    q.testing_lab_name,
    q.testing_lab_code
   FROM openchpl.certified_product a
     LEFT JOIN ( 
	   SELECT cse.certification_status_id,
       		cse.certified_product_id,
            cse.event_date AS last_certification_status_change
       FROM openchpl.certification_status_event cse
         INNER JOIN ( 
		   SELECT certification_status_event.certified_product_id,
           		max(certification_status_event.event_date) AS event_date
           FROM openchpl.certification_status_event
		   WHERE deleted <> true
           GROUP BY certification_status_event.certified_product_id) cseinner 
		 ON cse.certified_product_id = cseinner.certified_product_id 
		 AND cse.event_date = cseinner.event_date 
		WHERE cse.deleted <> true) r
	   ON r.certified_product_id = a.certified_product_id
     LEFT JOIN ( SELECT certification_status.certification_status_id,
            certification_status.certification_status AS certification_status_name
           FROM openchpl.certification_status) n ON r.certification_status_id = n.certification_status_id
     LEFT JOIN ( SELECT certification_edition.certification_edition_id,
            certification_edition.year
           FROM openchpl.certification_edition) b ON a.certification_edition_id = b.certification_edition_id
     LEFT JOIN ( SELECT certification_body.certification_body_id,
            certification_body.name AS certification_body_name,
            certification_body.acb_code AS certification_body_code,
            certification_body.deleted AS acb_is_deleted
           FROM openchpl.certification_body) c ON a.certification_body_id = c.certification_body_id
     LEFT JOIN ( SELECT product_classification_type.product_classification_type_id,
            product_classification_type.name AS product_classification_name
           FROM openchpl.product_classification_type) d ON a.product_classification_type_id = d.product_classification_type_id
     LEFT JOIN ( SELECT practice_type.practice_type_id,
            practice_type.name AS practice_type_name
           FROM openchpl.practice_type) e ON a.practice_type_id = e.practice_type_id
     LEFT JOIN ( SELECT product_version.product_version_id,
            product_version.version AS product_version,
            product_version.product_id
           FROM openchpl.product_version) f ON a.product_version_id = f.product_version_id
     LEFT JOIN ( SELECT product.product_id,
            product.vendor_id,
            product.name AS product_name
           FROM openchpl.product) g ON f.product_id = g.product_id
     LEFT JOIN ( SELECT vendor.vendor_id,
            vendor.name AS vendor_name,
            vendor.vendor_code,
            vendor.website AS vendor_website,
            vendor.address_id AS vendor_address,
            vendor.contact_id AS vendor_contact,
            vendor.vendor_status_id
           FROM openchpl.vendor) h ON g.vendor_id = h.vendor_id
     LEFT JOIN ( SELECT acb_vendor_map.vendor_id,
            acb_vendor_map.certification_body_id,
            acb_vendor_map.transparency_attestation
           FROM openchpl.acb_vendor_map) p ON h.vendor_id = p.vendor_id AND a.certification_body_id = p.certification_body_id
     LEFT JOIN ( SELECT address.address_id,
            address.street_line_1,
            address.street_line_2,
            address.city,
            address.state,
            address.zipcode,
            address.country
           FROM openchpl.address) t ON h.vendor_address = t.address_id
     LEFT JOIN ( SELECT contact.contact_id,
            contact.first_name,
            contact.last_name,
            contact.email,
            contact.phone_number,
            contact.title
           FROM openchpl.contact) u ON h.vendor_contact = u.contact_id
     LEFT JOIN ( SELECT vshistory.vendor_status_id,
            vshistory.vendor_id,
            vshistory.status_date AS last_vendor_status_change
           FROM openchpl.vendor_status_history vshistory
             JOIN ( SELECT vendor_status_history.vendor_id,
                    max(vendor_status_history.status_date) AS status_date
                   FROM openchpl.vendor_status_history
                  WHERE vendor_status_history.deleted = false
                  GROUP BY vendor_status_history.vendor_id) vsinner ON vshistory.vendor_id = vsinner.vendor_id AND vshistory.status_date = vsinner.status_date) vendorstatus ON vendorstatus.vendor_id = h.vendor_id
     LEFT JOIN ( SELECT vendor_status.vendor_status_id,
            vendor_status.name AS vendor_status_name
           FROM openchpl.vendor_status) v ON vendorstatus.vendor_status_id = v.vendor_status_id
     LEFT JOIN ( SELECT min(certification_status_event.event_date) AS certification_date,
            certification_status_event.certified_product_id
           FROM openchpl.certification_status_event
          WHERE certification_status_event.certification_status_id = 1
          GROUP BY certification_status_event.certified_product_id) i ON a.certified_product_id = i.certified_product_id
     LEFT JOIN ( SELECT max(certification_status_event.event_date) AS decertification_date,
            certification_status_event.certified_product_id
           FROM openchpl.certification_status_event
          WHERE certification_status_event.certification_status_id = ANY (ARRAY[3::bigint, 4::bigint, 8::bigint])
          GROUP BY certification_status_event.certified_product_id) decert ON a.certified_product_id = decert.certified_product_id
     LEFT JOIN ( SELECT j.certified_product_id,
            count(*) AS count_certifications
           FROM ( SELECT certification_result.certification_result_id,
                    certification_result.certification_criterion_id,
                    certification_result.certified_product_id,
                    certification_result.success,
                    certification_result.gap,
                    certification_result.sed,
                    certification_result.g1_success,
                    certification_result.g2_success,
                    certification_result.api_documentation,
                    certification_result.privacy_security_framework,
                    certification_result.creation_date,
                    certification_result.last_modified_date,
                    certification_result.last_modified_user,
                    certification_result.deleted
                   FROM openchpl.certification_result
                  WHERE certification_result.success = true AND certification_result.deleted <> true) j
          GROUP BY j.certified_product_id) k ON a.certified_product_id = k.certified_product_id
     LEFT JOIN ( SELECT l.certified_product_id,
            count(*) AS count_cqms
           FROM (SELECT DISTINCT
    						a.certified_product_id,
    						COALESCE(b.cms_id, b.nqf_number) AS cqm_id
   					FROM openchpl.cqm_result a
     					LEFT JOIN openchpl.cqm_criterion b 
							ON a.cqm_criterion_id = b.cqm_criterion_id
					WHERE a.success = true
					AND a.deleted <> true
					AND b.deleted <> true) l
          GROUP BY l.certified_product_id
          ORDER BY l.certified_product_id) m ON a.certified_product_id = m.certified_product_id
     LEFT JOIN ( SELECT n_1.certified_product_id,
            count(*) AS count_surveillance_activities
           FROM ( SELECT surveillance.id,
                    surveillance.certified_product_id,
                    surveillance.friendly_id,
                    surveillance.start_date,
                    surveillance.end_date,
                    surveillance.type_id,
                    surveillance.randomized_sites_used,
                    surveillance.creation_date,
                    surveillance.last_modified_date,
                    surveillance.last_modified_user,
                    surveillance.deleted,
                    surveillance.user_permission_id
                   FROM openchpl.surveillance
                  WHERE surveillance.deleted <> true) n_1
          GROUP BY n_1.certified_product_id) surv ON a.certified_product_id = surv.certified_product_id
     LEFT JOIN ( SELECT n_1.certified_product_id,
            count(*) AS count_open_surveillance_activities
           FROM ( SELECT surveillance.id,
                    surveillance.certified_product_id,
                    surveillance.friendly_id,
                    surveillance.start_date,
                    surveillance.end_date,
                    surveillance.type_id,
                    surveillance.randomized_sites_used,
                    surveillance.creation_date,
                    surveillance.last_modified_date,
                    surveillance.last_modified_user,
                    surveillance.deleted,
                    surveillance.user_permission_id
                   FROM openchpl.surveillance
                  WHERE surveillance.deleted <> true AND surveillance.start_date <= now() AND (surveillance.end_date IS NULL OR surveillance.end_date >= now())) n_1
          GROUP BY n_1.certified_product_id) surv_open ON a.certified_product_id = surv_open.certified_product_id
     LEFT JOIN ( SELECT n_1.certified_product_id,
            count(*) AS count_closed_surveillance_activities
           FROM ( SELECT surveillance.id,
                    surveillance.certified_product_id,
                    surveillance.friendly_id,
                    surveillance.start_date,
                    surveillance.end_date,
                    surveillance.type_id,
                    surveillance.randomized_sites_used,
                    surveillance.creation_date,
                    surveillance.last_modified_date,
                    surveillance.last_modified_user,
                    surveillance.deleted,
                    surveillance.user_permission_id
                   FROM openchpl.surveillance
                  WHERE surveillance.deleted <> true AND surveillance.start_date <= now() AND surveillance.end_date IS NOT NULL AND surveillance.end_date <= now()) n_1
          GROUP BY n_1.certified_product_id) surv_closed ON a.certified_product_id = surv_closed.certified_product_id
     LEFT JOIN ( SELECT n_1.certified_product_id,
            count(*) AS count_open_nonconformities
           FROM ( SELECT surv_1.id,
                    surv_1.certified_product_id,
                    surv_1.friendly_id,
                    surv_1.start_date,
                    surv_1.end_date,
                    surv_1.type_id,
                    surv_1.randomized_sites_used,
                    surv_1.creation_date,
                    surv_1.last_modified_date,
                    surv_1.last_modified_user,
                    surv_1.deleted,
                    surv_1.user_permission_id,
                    surv_req.id,
                    surv_req.surveillance_id,
                    surv_req.type_id,
                    surv_req.certification_criterion_id,
                    surv_req.requirement,
                    surv_req.result_id,
                    surv_req.creation_date,
                    surv_req.last_modified_date,
                    surv_req.last_modified_user,
                    surv_req.deleted,
                    surv_nc.id,
                    surv_nc.surveillance_requirement_id,
                    surv_nc.certification_criterion_id,
                    surv_nc.nonconformity_type,
                    surv_nc.nonconformity_status_id,
                    surv_nc.date_of_determination,
                    surv_nc.corrective_action_plan_approval_date,
                    surv_nc.corrective_action_start_date,
                    surv_nc.corrective_action_must_complete_date,
                    surv_nc.corrective_action_end_date,
                    surv_nc.summary,
                    surv_nc.findings,
                    surv_nc.sites_passed,
                    surv_nc.total_sites,
                    surv_nc.developer_explanation,
                    surv_nc.resolution,
                    surv_nc.creation_date,
                    surv_nc.last_modified_date,
                    surv_nc.last_modified_user,
                    surv_nc.deleted,
                    nc_status.id,
                    nc_status.name,
                    nc_status.creation_date,
                    nc_status.last_modified_date,
                    nc_status.last_modified_user,
                    nc_status.deleted
                   FROM openchpl.surveillance surv_1
                     JOIN openchpl.surveillance_requirement surv_req ON surv_1.id = surv_req.surveillance_id AND surv_req.deleted <> true
                     JOIN openchpl.surveillance_nonconformity surv_nc ON surv_req.id = surv_nc.surveillance_requirement_id AND surv_nc.deleted <> true
                     JOIN openchpl.nonconformity_status nc_status ON surv_nc.nonconformity_status_id = nc_status.id
                  WHERE surv_1.deleted <> true AND nc_status.name::text = 'Open'::text) n_1(id, certified_product_id, friendly_id, start_date, end_date, type_id, randomized_sites_used, creation_date, last_modified_date, last_modified_user, deleted, user_permission_id, id_1, surveillance_id, type_id_1, certification_criterion_id, requirement, result_id, creation_date_1, last_modified_date_1, last_modified_user_1, deleted_1, id_2, surveillance_requirement_id, certification_criterion_id_1, nonconformity_type, nonconformity_status_id, date_of_determination, corrective_action_plan_approval_date, corrective_action_start_date, corrective_action_must_complete_date, corrective_action_end_date, summary, findings, sites_passed, total_sites, developer_explanation, resolution, creation_date_2, last_modified_date_2, last_modified_user_2, deleted_2, id_3, name, creation_date_3, last_modified_date_3, last_modified_user_3, deleted_3)
          GROUP BY n_1.certified_product_id) nc_open ON a.certified_product_id = nc_open.certified_product_id
     LEFT JOIN ( SELECT n_1.certified_product_id,
            count(*) AS count_closed_nonconformities
           FROM ( SELECT surv_1.id,
                    surv_1.certified_product_id,
                    surv_1.friendly_id,
                    surv_1.start_date,
                    surv_1.end_date,
                    surv_1.type_id,
                    surv_1.randomized_sites_used,
                    surv_1.creation_date,
                    surv_1.last_modified_date,
                    surv_1.last_modified_user,
                    surv_1.deleted,
                    surv_1.user_permission_id,
                    surv_req.id,
                    surv_req.surveillance_id,
                    surv_req.type_id,
                    surv_req.certification_criterion_id,
                    surv_req.requirement,
                    surv_req.result_id,
                    surv_req.creation_date,
                    surv_req.last_modified_date,
                    surv_req.last_modified_user,
                    surv_req.deleted,
                    surv_nc.id,
                    surv_nc.surveillance_requirement_id,
                    surv_nc.certification_criterion_id,
                    surv_nc.nonconformity_type,
                    surv_nc.nonconformity_status_id,
                    surv_nc.date_of_determination,
                    surv_nc.corrective_action_plan_approval_date,
                    surv_nc.corrective_action_start_date,
                    surv_nc.corrective_action_must_complete_date,
                    surv_nc.corrective_action_end_date,
                    surv_nc.summary,
                    surv_nc.findings,
                    surv_nc.sites_passed,
                    surv_nc.total_sites,
                    surv_nc.developer_explanation,
                    surv_nc.resolution,
                    surv_nc.creation_date,
                    surv_nc.last_modified_date,
                    surv_nc.last_modified_user,
                    surv_nc.deleted,
                    nc_status.id,
                    nc_status.name,
                    nc_status.creation_date,
                    nc_status.last_modified_date,
                    nc_status.last_modified_user,
                    nc_status.deleted
                   FROM openchpl.surveillance surv_1
                     JOIN openchpl.surveillance_requirement surv_req ON surv_1.id = surv_req.surveillance_id AND surv_req.deleted <> true
                     JOIN openchpl.surveillance_nonconformity surv_nc ON surv_req.id = surv_nc.surveillance_requirement_id AND surv_nc.deleted <> true
                     JOIN openchpl.nonconformity_status nc_status ON surv_nc.nonconformity_status_id = nc_status.id
                  WHERE surv_1.deleted <> true AND nc_status.name::text = 'Closed'::text) n_1(id, certified_product_id, friendly_id, start_date, end_date, type_id, randomized_sites_used, creation_date, last_modified_date, last_modified_user, deleted, user_permission_id, id_1, surveillance_id, type_id_1, certification_criterion_id, requirement, result_id, creation_date_1, last_modified_date_1, last_modified_user_1, deleted_1, id_2, surveillance_requirement_id, certification_criterion_id_1, nonconformity_type, nonconformity_status_id, date_of_determination, corrective_action_plan_approval_date, corrective_action_start_date, corrective_action_must_complete_date, corrective_action_end_date, summary, findings, sites_passed, total_sites, developer_explanation, resolution, creation_date_2, last_modified_date_2, last_modified_user_2, deleted_2, id_3, name, creation_date_3, last_modified_date_3, last_modified_user_3, deleted_3)
          GROUP BY n_1.certified_product_id) nc_closed ON a.certified_product_id = nc_closed.certified_product_id
     LEFT JOIN ( SELECT testing_lab.testing_lab_id,
            testing_lab.name AS testing_lab_name,
            testing_lab.testing_lab_code
           FROM openchpl.testing_lab) q ON a.testing_lab_id = q.testing_lab_id;
		   
DROP VIEW IF EXISTS openchpl.certified_product_search;
CREATE OR REPLACE VIEW openchpl.certified_product_search AS

SELECT
    cp.certified_product_id,
    string_agg(DISTINCT (select chpl_product_number from openchpl.get_chpl_product_number(cp.certified_product_id))||'☹'||child.certified_product_id::text, '☺') as "child",
    string_agg(DISTINCT (select chpl_product_number from openchpl.get_chpl_product_number(cp.certified_product_id))||'☹'||parent.certified_product_id::text, '☺') as "parent",
    string_agg(DISTINCT certs.cert_number::text, '☺') as "certs",
    string_agg(DISTINCT cqms.cqm_number::text, '☺') as "cqms",
(select chpl_product_number from openchpl.get_chpl_product_number(cp.certified_product_id)) as "chpl_product_number",
 cp.meaningful_use_users,
 cp.transparency_attestation_url,
    edition.year,
    acb.certification_body_name,
    cp.acb_certification_id,
    prac.practice_type_name,
    version.product_version,
    product.product_name,
    vendor.vendor_name,
    string_agg(DISTINCT history_vendor_name::text, '☺') as "owner_history",
    certStatusEvent.certification_date,
    certStatus.certification_status_name,
 decert.decertification_date,
 string_agg(DISTINCT certs_with_api_documentation.cert_number::text||'☹'||certs_with_api_documentation.api_documentation, '☺') as "api_documentation",
    COALESCE(survs.count_surveillance_activities, 0) as "surveillance_count",
    COALESCE(nc_open.count_open_nonconformities, 0) as "open_nonconformity_count",
    COALESCE(nc_closed.count_closed_nonconformities, 0) as "closed_nonconformity_count"
 FROM openchpl.certified_product cp
 LEFT JOIN (SELECT cse.certification_status_id as "certification_status_id", cse.certified_product_id as "certified_product_id",
   cse.event_date as "last_certification_status_change"
    FROM openchpl.certification_status_event cse
    INNER JOIN (
     SELECT certified_product_id, MAX(event_date) event_date
     FROM openchpl.certification_status_event
     GROUP BY certified_product_id
    ) cseInner
    ON cse.certified_product_id = cseInner.certified_product_id AND cse.event_date = cseInner.event_date) certStatusEvents
  ON certStatusEvents.certified_product_id = cp.certified_product_id
    LEFT JOIN (SELECT certification_status_id, certification_status as "certification_status_name" FROM openchpl.certification_status) certStatus on certStatusEvents.certification_status_id = certStatus.certification_status_id
    LEFT JOIN (SELECT certified_product_id, chpl_product_number, child_listing_id, parent_listing_id FROM (SELECT certified_product_id, child_listing_id, parent_listing_id, chpl_product_number FROM openchpl.listing_to_listing_map INNER JOIN openchpl.certified_product on listing_to_listing_map.child_listing_id = certified_product.certified_product_id) children) child ON cp.certified_product_id = child.parent_listing_id
    LEFT JOIN (SELECT certified_product_id, chpl_product_number, child_listing_id, parent_listing_id FROM (SELECT certified_product_id, child_listing_id, parent_listing_id, chpl_product_number FROM openchpl.listing_to_listing_map INNER JOIN openchpl.certified_product on listing_to_listing_map.parent_listing_id = certified_product.certified_product_id) parents) parent ON cp.certified_product_id = parent.child_listing_id
    LEFT JOIN (SELECT certification_edition_id, year FROM openchpl.certification_edition) edition on cp.certification_edition_id = edition.certification_edition_id
    LEFT JOIN (SELECT certification_body_id, name as "certification_body_name", acb_code as "certification_body_code", deleted as "acb_is_deleted" FROM openchpl.certification_body) acb on cp.certification_body_id = acb.certification_body_id
    LEFT JOIN (SELECT practice_type_id, name as "practice_type_name" FROM openchpl.practice_type) prac on cp.practice_type_id = prac.practice_type_id
    LEFT JOIN (SELECT product_version_id, version as "product_version", product_id from openchpl.product_version) version on cp.product_version_id = version.product_version_id
    LEFT JOIN (SELECT product_id, vendor_id, name as "product_name" FROM openchpl.product) product ON version.product_id = product.product_id
    LEFT JOIN (SELECT vendor_id, name as "vendor_name", vendor_code FROM openchpl.vendor) vendor on product.vendor_id = vendor.vendor_id
    LEFT JOIN (SELECT name as "history_vendor_name", product_owner_history_map.product_id as "history_product_id" FROM openchpl.vendor
   JOIN openchpl.product_owner_history_map ON vendor.vendor_id = product_owner_history_map.vendor_id
   WHERE product_owner_history_map.deleted = false) owners
    ON owners.history_product_id = product.product_id
    LEFT JOIN (SELECT MIN(event_date) as "certification_date", certified_product_id from openchpl.certification_status_event where certification_status_id = 1 group by (certified_product_id)) certStatusEvent on cp.certified_product_id = certStatusEvent.certified_product_id
 LEFT JOIN (SELECT MAX(event_date) as "decertification_date", certified_product_id from openchpl.certification_status_event where certification_status_id IN (3, 4, 8) group by (certified_product_id)) decert on cp.certified_product_id = decert.certified_product_id
    LEFT JOIN (SELECT certified_product_id, count(*) as "count_surveillance_activities"
  FROM openchpl.surveillance
  WHERE openchpl.surveillance.deleted <> true
  GROUP BY certified_product_id) survs
    ON cp.certified_product_id = survs.certified_product_id
 LEFT JOIN (SELECT certified_product_id, count(*) as "count_open_nonconformities"
  FROM openchpl.surveillance surv
  JOIN openchpl.surveillance_requirement surv_req ON surv.id = surv_req.surveillance_id AND surv_req.deleted <> true
  JOIN openchpl.surveillance_nonconformity surv_nc ON surv_req.id = surv_nc.surveillance_requirement_id AND surv_nc.deleted <> true
  JOIN openchpl.nonconformity_status nc_status ON surv_nc.nonconformity_status_id = nc_status.id
  WHERE surv.deleted <> true
  AND nc_status.name = 'Open'
  GROUP BY certified_product_id) nc_open
    ON cp.certified_product_id = nc_open.certified_product_id
 LEFT JOIN (SELECT certified_product_id, count(*) as "count_closed_nonconformities"
  FROM openchpl.surveillance surv
  JOIN openchpl.surveillance_requirement surv_req ON surv.id = surv_req.surveillance_id AND surv_req.deleted <> true
  JOIN openchpl.surveillance_nonconformity surv_nc ON surv_req.id = surv_nc.surveillance_requirement_id AND surv_nc.deleted <> true
  JOIN openchpl.nonconformity_status nc_status ON surv_nc.nonconformity_status_id = nc_status.id
  WHERE surv.deleted <> true
  AND nc_status.name = 'Closed'
  GROUP BY certified_product_id) nc_closed
    ON cp.certified_product_id = nc_closed.certified_product_id
    LEFT JOIN (SELECT number as "cert_number", certified_product_id FROM openchpl.certification_criterion
  JOIN openchpl.certification_result ON certification_criterion.certification_criterion_id = certification_result.certification_criterion_id
  WHERE certification_result.success = true AND certification_result.deleted = false AND certification_criterion.deleted = false) certs
 ON certs.certified_product_id = cp.certified_product_id
 LEFT JOIN (SELECT number as "cert_number", api_documentation, certified_product_id FROM openchpl.certification_criterion
  JOIN openchpl.certification_result ON certification_criterion.certification_criterion_id = certification_result.certification_criterion_id
  WHERE certification_result.success = true
  AND certification_result.api_documentation IS NOT NULL
  AND certification_result.deleted = false
  AND certification_criterion.deleted = false) certs_with_api_documentation
 ON certs_with_api_documentation.certified_product_id = cp.certified_product_id
    LEFT JOIN (SELECT COALESCE(cms_id, 'NQF-'||nqf_number) as "cqm_number", certified_product_id FROM openchpl.cqm_criterion
  JOIN openchpl.cqm_result
  ON cqm_criterion.cqm_criterion_id = cqm_result.cqm_criterion_id
  WHERE cqm_result.success = true AND cqm_result.deleted = false AND cqm_criterion.deleted = false) cqms
 ON cqms.certified_product_id = cp.certified_product_id

WHERE cp.deleted != true
GROUP BY cp.certified_product_id, cp.acb_certification_id, edition.year, acb.certification_body_code, vendor.vendor_code, cp.product_code, cp.version_code,cp.ics_code, cp.additional_software_code, cp.certified_date_code, cp.transparency_attestation_url,
acb.certification_body_name,prac.practice_type_name,version.product_version,product.product_name,vendor.vendor_name,certStatusEvent.certification_date,certStatus.certification_status_name, decert.decertification_date,
survs.count_surveillance_activities, nc_open.count_open_nonconformities, nc_closed.count_closed_nonconformities
;

DROP VIEW openchpl.certified_product_search_result;
CREATE OR REPLACE VIEW openchpl.certified_product_search_result
AS
 SELECT all_listings_simple.*,
   certs_for_listing.cert_number,
   COALESCE(cqms_for_listing.cms_id, 'NQF-'||cqms_for_listing.nqf_number) as "cqm_number"
  FROM
  (SELECT
      cp.certified_product_id,
                    (select chpl_product_number from openchpl.get_chpl_product_number(cp.certified_product_id)),
   lastCertStatusEvent.certification_status_name,
   cp.meaningful_use_users,
   cp.transparency_attestation_url,
   edition.year,
   acb.certification_body_name,
   cp.acb_certification_id,
   prac.practice_type_name,
   version.product_version,
   product.product_name,
   vendor.vendor_name,
   history_vendor_name as "prev_vendor",
   certStatusEvent.certification_date,
   decert.decertification_date,
   COALESCE(count_surveillance_activities, 0) as "count_surveillance_activities",
   COALESCE(count_open_nonconformities, 0) as "count_open_nonconformities",
   COALESCE(count_closed_nonconformities, 0) as "count_closed_nonconformities"
  FROM openchpl.certified_product cp

  --certification date
  INNER JOIN (SELECT MIN(event_date) as "certification_date", certified_product_id from openchpl.certification_status_event where certification_status_id = 1 group by (certified_product_id)) certStatusEvent on cp.certified_product_id = certStatusEvent.certified_product_id

  --year
  INNER JOIN (SELECT certification_edition_id, year FROM openchpl.certification_edition) edition on cp.certification_edition_id = edition.certification_edition_id

  --ACB
  INNER JOIN (SELECT certification_body_id, name as "certification_body_name", acb_code as "certification_body_code", deleted as "acb_is_deleted" FROM openchpl.certification_body) acb on cp.certification_body_id = acb.certification_body_id

  -- version
  INNER JOIN (SELECT product_version_id, version as "product_version", product_id from openchpl.product_version) version on cp.product_version_id = version.product_version_id
  --product
  INNER JOIN (SELECT product_id, vendor_id, name as "product_name" FROM openchpl.product) product ON version.product_id = product.product_id
  --developer
  INNER JOIN (SELECT vendor_id, name as "vendor_name", vendor_code FROM openchpl.vendor) vendor on product.vendor_id = vendor.vendor_id

  --certification status
  INNER JOIN (
   SELECT certStatus.certification_status as "certification_status_name", cse.certified_product_id as "certified_product_id"
   FROM openchpl.certification_status_event cse
   INNER JOIN openchpl.certification_status certStatus ON cse.certification_status_id = certStatus.certification_status_id
   INNER JOIN
    (SELECT certified_product_id, extract(epoch from MAX(event_date)) event_date
    FROM openchpl.certification_status_event
    GROUP BY certified_product_id) maxCse
   ON cse.certified_product_id = maxCse.certified_product_id
   --conversion to epoch/long comparison significantly faster than comparing the timestamp fields as-is
   AND extract(epoch from cse.event_date) = maxCse.event_date
  ) lastCertStatusEvent
  ON lastCertStatusEvent.certified_product_id = cp.certified_product_id

  -- Practice type (2014 only)
  LEFT JOIN (SELECT practice_type_id, name as "practice_type_name" FROM openchpl.practice_type) prac on cp.practice_type_id = prac.practice_type_id

  --decertification date
  LEFT JOIN (SELECT MAX(event_date) as "decertification_date", certified_product_id from openchpl.certification_status_event where certification_status_id IN (3, 4, 8) group by (certified_product_id)) decert on cp.certified_product_id = decert.certified_product_id

  -- developer history
  LEFT JOIN (SELECT name as "history_vendor_name", product_owner_history_map.product_id as "history_product_id"
   FROM openchpl.vendor
   JOIN openchpl.product_owner_history_map ON vendor.vendor_id = product_owner_history_map.vendor_id
   WHERE product_owner_history_map.deleted = false) prev_vendor_owners
  ON prev_vendor_owners.history_product_id = product.product_id

  -- surveillance
  LEFT JOIN
                (SELECT certified_product_id, count(*) as "count_surveillance_activities"
                FROM openchpl.surveillance
                WHERE openchpl.surveillance.deleted <> true
                GROUP BY certified_product_id) survs
            ON cp.certified_product_id = survs.certified_product_id
            LEFT JOIN
                (SELECT certified_product_id, count(*) as "count_open_nonconformities"
                FROM openchpl.surveillance surv
                JOIN openchpl.surveillance_requirement surv_req ON surv.id = surv_req.surveillance_id AND surv_req.deleted <> true
                JOIN openchpl.surveillance_nonconformity surv_nc ON surv_req.id = surv_nc.surveillance_requirement_id AND surv_nc.deleted <> true
                JOIN openchpl.nonconformity_status nc_status ON surv_nc.nonconformity_status_id = nc_status.id
                WHERE surv.deleted <> true AND nc_status.name = 'Open'
                GROUP BY certified_product_id) nc_open
            ON cp.certified_product_id = nc_open.certified_product_id
            LEFT JOIN
                (SELECT certified_product_id, count(*) as "count_closed_nonconformities"
                FROM openchpl.surveillance surv
                JOIN openchpl.surveillance_requirement surv_req ON surv.id = surv_req.surveillance_id AND surv_req.deleted <> true
                JOIN openchpl.surveillance_nonconformity surv_nc ON surv_req.id = surv_nc.surveillance_requirement_id AND surv_nc.deleted <> true
                JOIN openchpl.nonconformity_status nc_status ON surv_nc.nonconformity_status_id = nc_status.id
                WHERE surv.deleted <> true AND nc_status.name = 'Closed'
                GROUP BY certified_product_id) nc_closed
            ON cp.certified_product_id = nc_closed.certified_product_id
 ) all_listings_simple
 --certs (adds so many rows to the result set it's faster to join it out here)
 LEFT OUTER JOIN
 (
  SELECT certification_criterion.number as "cert_number", certification_result.certified_product_id
  FROM openchpl.certification_result, openchpl.certification_criterion
  WHERE certification_criterion.certification_criterion_id = certification_result.certification_criterion_id
  AND certification_criterion.deleted = false
  AND certification_result.success = true
  AND certification_result.deleted = false
 ) certs_for_listing
 ON certs_for_listing.certified_product_id = all_listings_simple.certified_product_id
 --cqms (adds so many rows to the result set it's faster to join it out here)
 LEFT OUTER JOIN
 (
  SELECT cms_id, nqf_number, certified_product_id
  FROM openchpl.cqm_result, openchpl.cqm_criterion
  WHERE cqm_criterion.cqm_criterion_id = cqm_result.cqm_criterion_id
  AND cqm_criterion.deleted = false
  AND cqm_result.success = true
  AND cqm_result.deleted = false
 ) cqms_for_listing
 ON cqms_for_listing.certified_product_id = all_listings_simple.certified_product_id;

CREATE OR REPLACE VIEW openchpl.developers_with_attestations AS
SELECT
v.vendor_id as vendor_id,
v.name as vendor_name,
s.name as status_name,
sum(case when certification_status.certification_status = 'Active' then 1 else 0 end) as countActiveListings,
sum(case when certification_status.certification_status = 'Retired' then 1 else 0 end) as countRetiredListings,
sum(case when certification_status.certification_status = 'Pending' then 1 else 0 end) as countPendingListings,
sum(case when certification_status.certification_status = 'Withdrawn by Developer' then 1 else 0 end) as countWithdrawnByDeveloperListings,
sum(case when certification_status.certification_status = 'Withdrawn by ONC-ACB' then 1 else 0 end) as countWithdrawnByOncAcbListings,
sum(case when certification_status.certification_status = 'Suspended by ONC-ACB' then 1 else 0 end) as countSuspendedByOncAcbListings,
sum(case when certification_status.certification_status = 'Suspended by ONC' then 1 else 0 end) as countSuspendedByOncListings,
sum(case when certification_status.certification_status = 'Terminated by ONC' then 1 else 0 end) as countTerminatedByOncListings,
sum(case when certification_status.certification_status = 'Withdrawn by Developer Under Surveillance/Review' then 1 else 0 end) as countWithdrawnByDeveloperUnderSurveillanceListings,
string_agg(DISTINCT
 case when
  listings.transparency_attestation_url::text != ''
  and
   (certification_status.certification_status = 'Active'
   or
   certification_status.certification_status = 'Suspended by ONC'
   or
   certification_status.certification_status = 'Suspended by ONC-ACB')
  then listings.transparency_attestation_url::text else null end, '☺')
 as "transparency_attestation_urls",
--using coalesce here because the attestation can be null and concatting null with anything just gives null
--so null/empty attestations are left out unless we replace null with empty string
string_agg(DISTINCT acb.name::text||':'||COALESCE(attestations.transparency_attestation::text, ''), '☺') as "attestations"
FROM openchpl.vendor v
LEFT OUTER JOIN openchpl.vendor_status s ON v.vendor_status_id = s.vendor_status_id
LEFT OUTER JOIN openchpl.certified_product_details listings ON listings.vendor_id = v.vendor_id AND listings.deleted != true
LEFT OUTER JOIN openchpl.certification_status ON listings.certification_status_id = certification_status.certification_status_id
LEFT OUTER JOIN openchpl.acb_vendor_map attestations ON attestations.vendor_id = v.vendor_id AND attestations.deleted != true
LEFT OUTER JOIN openchpl.certification_body acb ON attestations.certification_body_id = acb.certification_body_id AND acb.deleted != true

WHERE v.deleted != true
GROUP BY v.vendor_id, v.name, s.name;

DROP VIEW openchpl.ehr_certification_ids_and_products;
CREATE OR REPLACE VIEW openchpl.ehr_certification_ids_and_products AS
SELECT
 row_number() OVER () AS id,
 ehr.ehr_certification_id_id as ehr_certification_id,
 ehr.certification_id as ehr_certification_id_text,
 ehr.creation_date as ehr_certification_id_creation_date,
 cp.certified_product_id,
 (select chpl_product_number from openchpl.get_chpl_product_number(cp.certified_product_id)),
 ed.year,
 (select testing_lab_code from openchpl.get_testing_lab_code(cp.certified_product_id)),
 acb.certification_body_code,
 v.vendor_code,
 cp.product_code,
    cp.version_code,
    cp.ics_code,
    cp.additional_software_code,
    cp.certified_date_code
FROM openchpl.ehr_certification_id ehr
    LEFT JOIN openchpl.ehr_certification_id_product_map prodMap
  ON ehr.ehr_certification_id_id = prodMap.ehr_certification_id_id
 LEFT JOIN openchpl.certified_product cp
  ON prodMap.certified_product_id = cp.certified_product_id
    LEFT JOIN (SELECT certification_edition_id, year FROM openchpl.certification_edition) ed on cp.certification_edition_id = ed.certification_edition_id
    LEFT JOIN (SELECT certification_body_id, name as "certification_body_name", acb_code as "certification_body_code" FROM openchpl.certification_body) acb
  ON cp.certification_body_id = acb.certification_body_id
 LEFT JOIN (SELECT product_version_id, product_id from openchpl.product_version) pv on cp.product_version_id = pv.product_version_id
    LEFT JOIN (SELECT product_id, vendor_id FROM openchpl.product) prod ON pv.product_id = prod.product_id
 LEFT JOIN (SELECT vendor_id, vendor_code from openchpl.vendor) v ON prod.vendor_id = v.vendor_id
;
--re-run grants
\i dev/openchpl_grant-all.sql

-- OCD-2142
-- bulk withdrawal of Listings
-- function returns false if one of a variety of conditions is true, indicated in comments
create or replace function openchpl.can_add_new_status(db_id bigint, eff_date timestamp, chpl_id varchar(64)) returns boolean as $$
    begin
-- most recent status is after effective date
    if (select cse.event_date from openchpl.certification_status_event cse where cse.certified_product_id = db_id order by cse.event_date desc limit 1) > eff_date then
    raise warning 'ID % cannot be updated as it has a later status CHPL ID: %', db_id, chpl_id;
    return false;
    end if;
-- most recent status is already "Withdrawn by Developer"
    if (select cse.certification_status_id from openchpl.certification_status_event cse where cse.certified_product_id = db_id order by cse.event_date desc limit 1) = 3 then
    raise warning 'ID % cannot be updated as it would be a double status CHPL ID: %', db_id, chpl_id;
    return false;
    end if;
-- most recent status anything other than "Active"
    if (select cse.certification_status_id from openchpl.certification_status_event cse where cse.certified_product_id = db_id order by cse.event_date desc limit 1) != 1 then
    raise warning 'ID % cannot be updated as Listing is not in status: Active CHPL ID: %', db_id, chpl_id;
    return false;
    end if;
-- has open surveillance
    if (select count(s.start_date) from openchpl.surveillance s where s.certified_product_id = db_id and s.end_date is null) > 0 then
    raise warning 'ID % cannot be updated as it has an open surveillance CHPL ID: %', db_id, chpl_id;
    return false;
    end if;
-- had open surveillance at effective date
    if (select count(*) from openchpl.surveillance s where s.certified_product_id = db_id and s.start_date < eff_date and s.end_date > eff_date) > 0 then
    raise warning 'ID % cannot be updated as it had an open surveillance at the effective date CHPL ID: %', db_id, chpl_id;
    return false;
    end if;
-- had any surveillance starting after effective date
    if (select count(*) from openchpl.surveillance s where s.certified_product_id = db_id and s.start_date > eff_date) > 0 then
    raise warning 'ID % cannot be updated as it had an opened surveillance after the effective date CHPL ID: %', db_id, chpl_id;
    return false;
    end if;
    return true;
    end;
    $$ language plpgsql
    stable;

create or replace function openchpl.add_new_status(db_id bigint, eff_date timestamp, chpl_id varchar(64)) returns void as $$
    begin
insert into openchpl.certification_status_event (certified_product_id, certification_status_id, event_date, last_modified_user) select db_id, 3, eff_date, -1
where openchpl.can_add_new_status(db_id, eff_date, chpl_id) = true;
    end;
    $$ language plpgsql;

--Intermountain Healthcare
select openchpl.add_new_status(7830, '2018-03-16', '14.07.07.1734.HEA1.02.01.1.160623');
select openchpl.add_new_status(7831, '2018-03-16', '14.07.07.1734.HEI1.02.01.1.160623');
select openchpl.add_new_status(7827, '2018-03-16', '14.07.07.1734.HEI1.01.01.1.160623');
select openchpl.add_new_status(7828, '2018-03-16', '14.07.07.1734.HEA1.01.01.1.160623');
select openchpl.add_new_status(7823, '2018-03-16', '14.07.07.1734.HEI1.03.01.1.160623');
select openchpl.add_new_status(7829, '2018-03-16', '14.07.07.1734.HEA1.03.01.1.160623');
select openchpl.add_new_status(7242, '2018-03-16', 'CHP-022458');
select openchpl.add_new_status(7243, '2018-03-16', 'CHP-022459');
select openchpl.add_new_status(6755, '2018-03-16', 'CHP-023253');
select openchpl.add_new_status(6757, '2018-03-16', 'CHP-023254');
select openchpl.add_new_status(6763, '2018-03-16', 'CHP-023257');
select openchpl.add_new_status(6765, '2018-03-16', 'CHP-023258');
select openchpl.add_new_status(6346, '2018-03-16', 'CHP-023341');
select openchpl.add_new_status(6348, '2018-03-16', 'CHP-023343');
select openchpl.add_new_status(6350, '2018-03-16', 'CHP-023344');
select openchpl.add_new_status(6352, '2018-03-16', 'CHP-023345');
select openchpl.add_new_status(6609, '2018-03-16', 'CHP-023641');
select openchpl.add_new_status(6619, '2018-03-16', 'CHP-023642');
select openchpl.add_new_status(6613, '2018-03-16', 'CHP-023643');
select openchpl.add_new_status(6615, '2018-03-16', 'CHP-023644');
select openchpl.add_new_status(6617, '2018-03-16', 'CHP-023645');
select openchpl.add_new_status(6621, '2018-03-16', 'CHP-023646');
select openchpl.add_new_status(6623, '2018-03-16', 'CHP-023647');
select openchpl.add_new_status(6625, '2018-03-16', 'CHP-023648');
select openchpl.add_new_status(5708, '2018-03-16', 'CHP-024519');
select openchpl.add_new_status(5696, '2018-03-16', 'CHP-024522');
select openchpl.add_new_status(6259, '2018-03-16', 'CHP-024741');
select openchpl.add_new_status(6261, '2018-03-16', 'CHP-024742');
select openchpl.add_new_status(6488, '2018-03-16', 'CHP-025082');
select openchpl.add_new_status(6490, '2018-03-16', 'CHP-025083');
select openchpl.add_new_status(6496, '2018-03-16', 'CHP-025087');
select openchpl.add_new_status(6498, '2018-03-16', 'CHP-025088');
select openchpl.add_new_status(6500, '2018-03-16', 'CHP-025089');
select openchpl.add_new_status(6502, '2018-03-16', 'CHP-025090');
select openchpl.add_new_status(7399, '2018-03-16', 'CHP-028656');
select openchpl.add_new_status(7400, '2018-03-16', 'CHP-028657');
select openchpl.add_new_status(7401, '2018-03-16', 'CHP-028658');
select openchpl.add_new_status(7402, '2018-03-16', 'CHP-028659');
select openchpl.add_new_status(7403, '2018-03-16', 'CHP-028660');
select openchpl.add_new_status(7404, '2018-03-16', 'CHP-028661');
select openchpl.add_new_status(7406, '2018-03-16', 'CHP-028663');
select openchpl.add_new_status(7407, '2018-03-16', 'CHP-028664');
select openchpl.add_new_status(7408, '2018-03-16', 'CHP-028665');
select openchpl.add_new_status(7410, '2018-03-16', 'CHP-028667');
select openchpl.add_new_status(7411, '2018-03-16', 'CHP-028668');
select openchpl.add_new_status(7412, '2018-03-16', 'CHP-028669');
select openchpl.add_new_status(7413, '2018-03-16', 'CHP-028670');
select openchpl.add_new_status(7414, '2018-03-16', 'CHP-028671');
select openchpl.add_new_status(7415, '2018-03-16', 'CHP-028672');
select openchpl.add_new_status(7416, '2018-03-16', 'CHP-028673');
select openchpl.add_new_status(7417, '2018-03-16', 'CHP-028674');
select openchpl.add_new_status(7418, '2018-03-16', 'CHP-028675');
select openchpl.add_new_status(7419, '2018-03-16', 'CHP-028676');
select openchpl.add_new_status(7420, '2018-03-16', 'CHP-028677');
select openchpl.add_new_status(7421, '2018-03-16', 'CHP-028678');
select openchpl.add_new_status(7422, '2018-03-16', 'CHP-028679');
select openchpl.add_new_status(6439, '2018-03-16', 'CHP-029134');
select openchpl.add_new_status(6417, '2018-03-16', 'CHP-029138');
select openchpl.add_new_status(6423, '2018-03-16', 'CHP-029141');
select openchpl.add_new_status(6435, '2018-03-16', 'CHP-029143');
select openchpl.add_new_status(6429, '2018-03-16', 'CHP-029145');
select openchpl.add_new_status(6431, '2018-03-16', 'CHP-029146');
select openchpl.add_new_status(6433, '2018-03-16', 'CHP-029147');
select openchpl.add_new_status(6441, '2018-03-16', 'CHP-029148');
select openchpl.add_new_status(6447, '2018-03-16', 'CHP-029151');
select openchpl.add_new_status(6449, '2018-03-16', 'CHP-029152');

--Cerner
select openchpl.add_new_status(8669, '2018-04-04', '14.07.07.1221.POI5.17.01.1.170327');
select openchpl.add_new_status(8096, '2018-04-04', '14.07.07.1221.POI7.04.01.0.161012');
select openchpl.add_new_status(8665, '2018-04-04', '14.07.07.1221.POA5.17.01.1.170327');
select openchpl.add_new_status(8488, '2018-04-04', '14.07.07.1221.PAA3.08.01.1.170308');
select openchpl.add_new_status(8726, '2018-04-04', '14.07.07.1221.FII4.14.01.0.170608');
select openchpl.add_new_status(7893, '2018-04-04', '14.03.07.1221.POA5.04.01.1.160711');
select openchpl.add_new_status(7998, '2018-04-04', '14.07.07.1221.CEA1.05.01.0.160901');
select openchpl.add_new_status(7886, '2018-04-04', '14.03.07.1221.FIA1.02.01.1.160711');
select openchpl.add_new_status(8716, '2018-04-04', '14.07.07.1221.POA5.20.01.1.170519');
select openchpl.add_new_status(8095, '2018-04-04', '14.07.07.1221.POI7.05.01.0.161012');
select openchpl.add_new_status(8686, '2018-04-04', '14.07.07.1221.POI5.18.01.1.170426');
select openchpl.add_new_status(8675, '2018-04-04', '14.07.07.1221.FII4.11.01.0.170426');
select openchpl.add_new_status(7876, '2018-04-04', '14.03.07.1221.POI5.02.01.1.160711');
select openchpl.add_new_status(8643, '2018-04-04', '14.07.07.1221.FII1.11.01.1.170321');
select openchpl.add_new_status(8583, '2018-04-04', '14.07.07.1221.CEA1.18.01.0.170721');
select openchpl.add_new_status(8404, '2018-04-04', '14.07.07.1221.POA1.09.01.1.170308');
select openchpl.add_new_status(8727, '2018-04-04', '14.07.07.1221.HEA2.21.01.1.170608');
select openchpl.add_new_status(7884, '2018-04-04', '14.03.07.1221.HEI2.02.01.1.160711');
select openchpl.add_new_status(7977, '2018-04-04', '14.03.07.1222.FIAM.99.01.1.140818');
select openchpl.add_new_status(8420, '2018-04-04', '14.07.07.1221.FII4.08.01.0.170308');
select openchpl.add_new_status(9116, '2018-04-04', '14.07.07.1221.PO08.12.01.0.171110');
select openchpl.add_new_status(7871, '2018-04-04', '14.03.07.1221.PAA3.04.01.1.160711');
select openchpl.add_new_status(8691, '2018-04-04', '14.07.07.1221.FII3.12.01.1.170510');
select openchpl.add_new_status(8397, '2018-04-04', '14.07.07.1221.FII1.09.01.1.170308');
select openchpl.add_new_status(8432, '2018-04-04', '14.07.07.1221.POI3.09.01.1.170308');
select openchpl.add_new_status(8198, '2018-04-04', '14.07.07.1221.CEA1.12.01.0.161122');
select openchpl.add_new_status(8693, '2018-04-04', '14.07.07.1221.HEA2.19.01.1.170510');
select openchpl.add_new_status(8441, '2018-04-04', '14.07.07.1221.POA1.13.01.1.170308');
select openchpl.add_new_status(8437, '2018-04-04', '14.07.07.1221.POI3.11.01.1.170308');
select openchpl.add_new_status(7930, '2018-04-04', '14.03.07.1221.FII4.04.01.0.160711');
select openchpl.add_new_status(8413, '2018-04-04', '14.07.07.1221.POA4.08.01.0.170308');
select openchpl.add_new_status(7890, '2018-04-04', '14.03.07.1221.FIA4.03.01.0.160711');
select openchpl.add_new_status(9140, '2018-04-04', '14.07.07.1221.PO04.20.01.0.171110');
select openchpl.add_new_status(8422, '2018-04-04', '14.07.07.1221.FIA2.09.01.1.170308');
select openchpl.add_new_status(8664, '2018-04-04', '14.07.07.1221.POA4.11.01.0.170327');
select openchpl.add_new_status(8029, '2018-04-04', '14.07.07.1221.FII4.04.01.0.160906');
select openchpl.add_new_status(8706, '2018-04-04', '14.07.07.1221.FIA4.13.01.0.170519');
select openchpl.add_new_status(8695, '2018-04-04', '14.07.07.1221.HEI3.13.01.1.170510');
select openchpl.add_new_status(8733, '2018-04-04', '14.07.07.1221.POA5.21.01.1.170608');
select openchpl.add_new_status(7891, '2018-04-04', '14.03.07.1221.POI3.02.01.1.160711');
select openchpl.add_new_status(7922, '2018-04-04', '14.03.07.1221.FII3.02.01.1.160711');
select openchpl.add_new_status(7899, '2018-04-04', '14.03.07.1221.FIA2.04.01.1.160711');
select openchpl.add_new_status(8393, '2018-04-04', '14.07.07.1221.POI5.14.01.1.170308');
select openchpl.add_new_status(8711, '2018-04-04', '14.07.07.1221.HEA3.14.01.1.170519');
select openchpl.add_new_status(8656, '2018-04-04', '14.07.07.1221.FII1.12.01.1.170327');
select openchpl.add_new_status(8197, '2018-04-04', '14.07.07.1221.CEI1.11.01.0.161122');
select openchpl.add_new_status(8382, '2018-04-04', '14.07.07.1221.HEI2.09.01.1.170308');
select openchpl.add_new_status(8775, '2018-04-04', '14.07.07.1221.FIA4.17.01.0.170727');
select openchpl.add_new_status(8700, '2018-04-04', '14.07.07.1221.POI2.19.01.1.170510');
select openchpl.add_new_status(8679, '2018-04-04', '14.07.07.1221.HEI3.12.01.1.170426');
select openchpl.add_new_status(8001, '2018-04-04', '14.07.07.1221.CEI1.08.01.0.160901');
select openchpl.add_new_status(8729, '2018-04-04', '14.07.07.1221.HEI2.21.01.1.170608');
select openchpl.add_new_status(8094, '2018-04-04', '14.07.07.1221.POA6.05.01.1.161012');
select openchpl.add_new_status(8100, '2018-04-04', '14.07.07.1221.POA6.03.01.1.161012');
select openchpl.add_new_status(8677, '2018-04-04', '14.07.07.1221.HEA3.12.01.1.170426');
select openchpl.add_new_status(8723, '2018-04-04', '14.07.07.1221.FIA4.14.01.0.170608');
select openchpl.add_new_status(8167, '2018-04-04', '14.07.07.1221.POA4.04.01.0.161108');
select openchpl.add_new_status(8584, '2018-04-04', '14.07.07.1221.CEI1.18.01.0.170721');
select openchpl.add_new_status(8456, '2018-04-04', '14.07.07.1221.POA8.08.01.1.170313');
select openchpl.add_new_status(8762, '2018-04-04', '14.07.07.1221.HEA2.23.01.1.170711');
select openchpl.add_new_status(8586, '2018-04-04', '14.07.07.1221.CEA1.17.01.0.170721');
select openchpl.add_new_status(8663, '2018-04-04', '14.07.07.1221.POA1.17.01.1.170327');
select openchpl.add_new_status(9024, '2018-04-04', '14.07.07.1221.FII4.23.01.0.171206');
select openchpl.add_new_status(7877, '2018-04-04', '14.03.07.1221.POA5.02.01.1.160711');
select openchpl.add_new_status(8661, '2018-04-04', '14.07.07.1221.HEI2.17.01.1.170327');
select openchpl.add_new_status(7872, '2018-04-04', '14.03.07.1221.PAI3.04.01.1.160711');
select openchpl.add_new_status(8004, '2018-04-04', '14.07.07.1221.CEI1.09.01.0.160901');
select openchpl.add_new_status(8438, '2018-04-04', '14.07.07.1221.POA5.09.01.1.170308');
select openchpl.add_new_status(8935, '2018-04-04', '14.07.07.1221.PO04.21.01.0.171110');
select openchpl.add_new_status(7758, '2018-04-04', '14.07.07.1221.CEI1.03.01.0.160502');
select openchpl.add_new_status(8435, '2018-04-04', '14.07.07.1221.POI2.09.01.1.170308');
select openchpl.add_new_status(8924, '2018-04-04', '14.07.07.1221.FI04.19.01.0.171110');
select openchpl.add_new_status(8429, '2018-04-04', '14.07.07.1221.POI3.14.01.1.170308');
select openchpl.add_new_status(8735, '2018-04-04', '14.07.07.1221.POI3.21.01.1.170608');
select openchpl.add_new_status(8766, '2018-04-04', '14.07.07.1221.POA4.17.01.0.170711');
select openchpl.add_new_status(7932, '2018-04-04', '14.03.07.1221.POA4.04.01.0.160711');
select openchpl.add_new_status(8722, '2018-04-04', '14.07.07.1221.FIA2.15.01.1.170608');
select openchpl.add_new_status(7868, '2018-04-04', '14.03.07.1221.FII4.03.01.0.160711');
select openchpl.add_new_status(8307, '2018-04-04', '14.07.07.1221.POI8.06.01.0.170120');
select openchpl.add_new_status(8202, '2018-04-04', '14.07.07.1221.CEI1.10.01.0.161122');
select openchpl.add_new_status(8309, '2018-04-04', '14.07.07.1221.POI8.07.01.0.170120');
select openchpl.add_new_status(8713, '2018-04-04', '14.07.07.1221.POA1.20.01.1.170519');
select openchpl.add_new_status(7995, '2018-04-04', '14.07.07.1221.CEI1.06.01.0.160901');
select openchpl.add_new_status(9038, '2018-04-04', '14.07.07.1221.CEI1.22.01.0.171206');
select openchpl.add_new_status(7875, '2018-04-04', '14.03.07.1221.PAI3.03.01.1.160711');
select openchpl.add_new_status(8724, '2018-04-04', '14.07.07.1221.FII1.16.01.1.170608');
select openchpl.add_new_status(7752, '2018-04-04', '14.07.07.1221.CEA1.04.01.0.160502');
select openchpl.add_new_status(7914, '2018-04-04', '14.03.07.1221.FII4.01.01.0.160711');
select openchpl.add_new_status(8905, '2018-04-04', '14.07.07.1221.PO08.13.01.1.171109');
select openchpl.add_new_status(9009, '2018-04-04', '14.07.07.1221.POA4.24.01.0.171206');
select openchpl.add_new_status(7918, '2018-04-04', '14.03.07.1221.PAI3.01.01.1.160711');
select openchpl.add_new_status(7933, '2018-04-04', '14.07.07.1221.POA1.02.01.1.160711');
select openchpl.add_new_status(8684, '2018-04-04', '14.07.07.1221.POI3.18.01.1.170426');
select openchpl.add_new_status(7898, '2018-04-04', '14.03.07.1221.POI4.04.01.0.160711');
select openchpl.add_new_status(8909, '2018-04-04', '14.07.07.1221.FI04.21.01.0.171109');
select openchpl.add_new_status(7996, '2018-04-04', '14.07.07.1221.CEI1.05.01.0.160901');
select openchpl.add_new_status(8950, '2018-04-04', '14.07.07.1221.PO04.22.01.0.171110');
select openchpl.add_new_status(7912, '2018-04-04', '14.03.07.1221.POI4.01.01.0.160711');
select openchpl.add_new_status(8689, '2018-04-04', '14.07.07.1221.FIA4.12.01.0.170510');
select openchpl.add_new_status(8929, '2018-04-04', '14.07.07.1221.PO04.20.01.0.171110');
select openchpl.add_new_status(8761, '2018-04-04', '14.07.07.1221.FII4.16.01.0.170711');
select openchpl.add_new_status(8712, '2018-04-04', '14.07.07.1221.HEI2.20.01.1.170519');
select openchpl.add_new_status(8911, '2018-04-04', '14.07.07.1221.FI04.20.01.0.171109');
select openchpl.add_new_status(8634, '2018-04-04', '14.07.07.1221.PAI3.09.01.1.170320');
select openchpl.add_new_status(8763, '2018-04-04', '14.07.07.1221.HEA3.17.01.1.170711');
select openchpl.add_new_status(8402, '2018-04-04', '14.07.07.1221.HEA2.11.01.1.170308');
select openchpl.add_new_status(8457, '2018-04-04', '14.07.07.1221.POA8.09.01.1.170313');
select openchpl.add_new_status(8199, '2018-04-04', '14.07.07.1221.CEI1.12.01.0.161122');
select openchpl.add_new_status(8671, '2018-04-04', '14.07.07.1221.FIA2.12.01.1.170426');
select openchpl.add_new_status(9043, '2018-04-04', '15.07.07.1221.SO05.01.00.1.171117');
select openchpl.add_new_status(8898, '2018-04-04', '14.07.07.1221.FI04.19.01.0.171109');
select openchpl.add_new_status(8002, '2018-04-04', '14.07.07.1221.CEI1.08.01.0.160901');
select openchpl.add_new_status(7903, '2018-04-04', '14.03.07.1221.POA4.01.01.0.160711');
select openchpl.add_new_status(8648, '2018-04-04', '14.07.07.1221.POA5.16.01.1.170321');
select openchpl.add_new_status(8941, '2018-04-04', '14.07.07.1221.FI04.21.01.0.171110');
select openchpl.add_new_status(8662, '2018-04-04', '14.07.07.1221.HEI3.11.01.1.170327');
select openchpl.add_new_status(8018, '2018-04-04', '14.07.07.1221.PAI3.04.01.1.160906');
select openchpl.add_new_status(8385, '2018-04-04', '14.07.07.1221.HEI2.12.01.1.170308');
select openchpl.add_new_status(8445, '2018-04-04', '14.07.07.1221.POA1.14.01.1.170308');
select openchpl.add_new_status(9123, '2018-04-04', '14.07.07.1221.PO08.11.01.0.171110');
select openchpl.add_new_status(8399, '2018-04-04', '14.07.07.1221.FIA1.09.01.1.170308');
select openchpl.add_new_status(8582, '2018-04-04', '14.07.07.1221.CEA1.19.01.0.170721');
select openchpl.add_new_status(8705, '2018-04-04', '14.07.07.1221.FIA2.14.01.1.170519');
select openchpl.add_new_status(8660, '2018-04-04', '14.07.07.1221.HEA3.11.01.1.170327');
select openchpl.add_new_status(8916, '2018-04-04', '14.07.07.1221.PO08.14.01.1.171109');
select openchpl.add_new_status(8160, '2018-04-04', '14.07.07.1221.PAI3.04.01.1.161108');
select openchpl.add_new_status(8910, '2018-04-04', '14.07.07.1221.PO04.21.01.0.171109');
select openchpl.add_new_status(9016, '2018-04-04', '14.07.07.1221.FIA4.22.01.0.171206');
select openchpl.add_new_status(8948, '2018-04-04', '14.07.07.1221.CE01.20.01.0.171110');
select openchpl.add_new_status(8274, '2018-04-04', '14.07.07.1221.POA4.04.01.0.161227');
select openchpl.add_new_status(8721, '2018-04-04', '14.07.07.1221.FIA1.16.01.1.170608');
select openchpl.add_new_status(8698, '2018-04-04', '14.07.07.1221.POA4.13.01.0.170510');
select openchpl.add_new_status(9137, '2018-04-04', '14.07.07.1221.FI04.19.01.0.171110');
select openchpl.add_new_status(8687, '2018-04-04', '14.07.07.1221.FIA1.14.01.1.170510');
select openchpl.add_new_status(8460, '2018-04-04', '14.07.07.1221.POI8.10.01.0.170313');
select openchpl.add_new_status(8674, '2018-04-04', '14.07.07.1221.FII3.11.01.1.170426');
select openchpl.add_new_status(8658, '2018-04-04', '14.07.07.1221.FII4.10.01.0.170327');
select openchpl.add_new_status(8389, '2018-04-04', '14.07.07.1221.HEI2.11.01.1.170308');
select openchpl.add_new_status(8657, '2018-04-04', '14.07.07.1221.FII3.10.01.1.170327');
select openchpl.add_new_status(8667, '2018-04-04', '14.07.07.1221.POI3.17.01.1.170327');
select openchpl.add_new_status(8728, '2018-04-04', '14.07.07.1221.HEA3.15.01.1.170608');
select openchpl.add_new_status(9139, '2018-04-04', '14.07.07.1221.FI04.21.01.0.171110');
select openchpl.add_new_status(7879, '2018-04-04', '14.03.07.1221.HEA2.02.01.1.160711');
select openchpl.add_new_status(8809, '2018-04-04', '14.07.07.1221.PAA3.10.01.1.170705');
select openchpl.add_new_status(8447, '2018-04-04', '14.07.07.1221.CEA1.16.01.0.170310');
select openchpl.add_new_status(9011, '2018-04-04', '14.07.07.1221.CEA4.02.01.0.171206');
select openchpl.add_new_status(7900, '2018-04-04', '14.07.07.1221.POA1.04.01.1.160711');
select openchpl.add_new_status(8395, '2018-04-04', '14.07.07.1221.POI5.13.01.1.170308');
select openchpl.add_new_status(7913, '2018-04-04', '14.03.07.1221.FIA4.01.01.0.160711');
select openchpl.add_new_status(8748, '2018-04-04', '14.07.07.1221.PAI3.10.01.1.170705');
select openchpl.add_new_status(8690, '2018-04-04', '14.07.07.1221.FII1.14.01.1.170510');
select openchpl.add_new_status(8270, '2018-04-04', '14.07.07.1221.FIA4.04.01.0.161227');
select openchpl.add_new_status(8201, '2018-04-04', '14.07.07.1221.CEA1.10.01.0.161122');
select openchpl.add_new_status(8670, '2018-04-04', '14.07.07.1221.FIA1.13.01.1.170426');
select openchpl.add_new_status(8697, '2018-04-04', '14.07.07.1221.POA1.19.01.1.170510');
select openchpl.add_new_status(7882, '2018-04-04', '14.03.07.1221.FIA1.04.01.1.160711');
select openchpl.add_new_status(8764, '2018-04-04', '14.07.07.1221.HEI2.23.01.1.170711');
select openchpl.add_new_status(8384, '2018-04-04', '14.07.07.1221.HEA2.12.01.1.170308');
select openchpl.add_new_status(8642, '2018-04-04', '14.07.07.1221.FIA1.11.01.1.170321');
select openchpl.add_new_status(8707, '2018-04-04', '14.07.07.1221.FII1.15.01.1.170519');
select openchpl.add_new_status(8434, '2018-04-04', '14.07.07.1221.POI2.13.01.1.170308');
select openchpl.add_new_status(8792, '2018-04-04', '14.07.07.1221.FIA4.18.01.0.170728');
select openchpl.add_new_status(8031, '2018-04-04', '14.07.07.1221.POI4.04.01.0.160906');
select openchpl.add_new_status(7755, '2018-04-04', '14.07.07.1221.CEI1.01.01.0.160502');
select openchpl.add_new_status(9045, '2018-04-04', '15.07.07.1221.FI01.08.01.1.171117');
select openchpl.add_new_status(9020, '2018-04-04', '14.07.07.1221.CEA1.22.01.0.171206');
select openchpl.add_new_status(8104, '2018-04-04', '14.07.07.1221.POI7.01.01.0.161012');
select openchpl.add_new_status(8626, '2018-04-04', '14.07.07.1221.FIA4.09.01.0.170320');
select openchpl.add_new_status(8159, '2018-04-04', '14.07.07.1221.FIA4.04.01.0.161108');
select openchpl.add_new_status(8758, '2018-04-04', '14.07.07.1221.FIA4.16.01.0.170711');
select openchpl.add_new_status(8298, '2018-04-04', '14.07.07.1221.CEA1.13.01.0.170116');
select openchpl.add_new_status(8752, '2018-04-04', '14.07.07.1221.FIA1.18.01.1.170711');
select openchpl.add_new_status(8903, '2018-04-04', '14.07.07.1221.CE01.20.01.0.171109');
select openchpl.add_new_status(8795, '2018-04-04', '14.07.07.1221.FII4.18.01.0.170728');
select openchpl.add_new_status(8631, '2018-04-04', '14.07.07.1221.FII4.09.01.0.170320');
select openchpl.add_new_status(8696, '2018-04-04', '14.07.07.1221.HEI2.19.01.1.170510');
select openchpl.add_new_status(8391, '2018-04-04', '14.07.07.1221.POI5.12.01.1.170308');
select openchpl.add_new_status(7873, '2018-04-04', '14.03.07.1221.PAA3.03.01.1.160711');
select openchpl.add_new_status(7902, '2018-04-04', '14.03.07.1221.POI2.04.01.1.160711');
select openchpl.add_new_status(8692, '2018-04-04', '14.07.07.1221.FII4.12.01.0.170510');
select openchpl.add_new_status(8768, '2018-04-04', '14.07.07.1221.POA1.23.01.1.170711');
select openchpl.add_new_status(9119, '2018-04-04', '14.07.07.1221.CE01.21.01.0.171110');
select openchpl.add_new_status(8308, '2018-04-04', '14.07.07.1221.POA8.07.01.1.170120');
select openchpl.add_new_status(8268, '2018-04-04', '14.07.07.1221.FII4.04.01.0.161227');
select openchpl.add_new_status(7751, '2018-04-04', '14.07.07.1221.CEA1.03.01.0.160502');
select openchpl.add_new_status(8778, '2018-04-04', '14.07.07.1221.FII4.17.01.0.170727');
select openchpl.add_new_status(8103, '2018-04-04', '14.07.07.1221.POI7.02.01.0.161012');
select openchpl.add_new_status(8442, '2018-04-04', '14.07.07.1221.POI3.12.01.1.170308');
select openchpl.add_new_status(8703, '2018-04-04', '14.07.07.1221.POI5.19.01.1.170510');
select openchpl.add_new_status(8788, '2018-04-04', '14.07.07.1221.POI4.18.01.0.170727');
select openchpl.add_new_status(8645, '2018-04-04', '14.07.07.1221.HEI2.16.01.1.170321');
select openchpl.add_new_status(8449, '2018-04-04', '14.07.07.1221.CEI1.16.01.0.170310');
select openchpl.add_new_status(8720, '2018-04-04', '14.07.07.1221.POI5.20.01.1.170519');
select openchpl.add_new_status(8731, '2018-04-04', '14.07.07.1221.POA1.21.01.1.170608');
select openchpl.add_new_status(8719, '2018-04-04', '14.07.07.1221.POI4.14.01.0.170519');
select openchpl.add_new_status(8949, '2018-04-04', '14.07.07.1221.CE01.21.01.0.171110');
select openchpl.add_new_status(8755, '2018-04-04', '14.07.07.1221.POI4.16.01.0.170705');
select openchpl.add_new_status(8897, '2018-04-04', '14.07.07.1221.PO04.20.01.0.171109');
select openchpl.add_new_status(7921, '2018-04-04', '14.03.07.1221.PAI3.02.01.1.160711');
select openchpl.add_new_status(9026, '2018-04-04', '14.07.07.1221.POI4.24.01.0.171206');
select openchpl.add_new_status(9144, '2018-04-04', '14.07.07.1221.FI04.20.01.0.171110');
select openchpl.add_new_status(8767, '2018-04-04', '14.07.07.1221.POA5.23.01.1.170711');
select openchpl.add_new_status(8757, '2018-04-04', '14.07.07.1221.FIA2.17.01.1.170711');
select openchpl.add_new_status(8653, '2018-04-04', '14.07.07.1221.FIA1.12.01.1.170327');
select openchpl.add_new_status(8405, '2018-04-04', '14.07.07.1221.POA1.10.01.1.170308');
select openchpl.add_new_status(7999, '2018-04-04', '14.07.07.1221.CEI1.07.01.0.160901');
select openchpl.add_new_status(9142, '2018-04-04', '14.07.07.1221.PA03.11.01.1.171110');
select openchpl.add_new_status(8458, '2018-04-04', '14.07.07.1221.POI8.08.01.0.170313');
select openchpl.add_new_status(8680, '2018-04-04', '14.07.07.1221.POA1.18.01.1.170426');
select openchpl.add_new_status(8644, '2018-04-04', '14.07.07.1221.HEA2.16.01.1.170321');
select openchpl.add_new_status(8102, '2018-04-04', '14.07.07.1221.POA7.01.01.1.161012');
select openchpl.add_new_status(8668, '2018-04-04', '14.07.07.1221.POI4.11.01.0.170327');
select openchpl.add_new_status(8200, '2018-04-04', '14.07.07.1221.CEA1.11.01.0.161122');
select openchpl.add_new_status(8646, '2018-04-04', '14.07.07.1221.POA1.16.01.1.170321');
select openchpl.add_new_status(8709, '2018-04-04', '14.07.07.1221.FII4.13.01.0.170519');
select openchpl.add_new_status(7895, '2018-04-04', '14.03.07.1221.POI3.04.01.1.160711');
select openchpl.add_new_status(8026, '2018-04-04', '14.07.07.1221.PAA3.04.01.1.160906');
select openchpl.add_new_status(8694, '2018-04-04', '14.07.07.1221.HEA3.13.01.1.170510');
select openchpl.add_new_status(8427, '2018-04-04', '14.07.07.1221.POI2.14.01.1.170308');
select openchpl.add_new_status(8715, '2018-04-04', '14.07.07.1221.POA4.14.01.0.170519');
select openchpl.add_new_status(8640, '2018-04-04', '14.07.07.1221.POI4.09.01.0.170320');
select openchpl.add_new_status(8704, '2018-04-04', '14.07.07.1221.FIA1.15.01.1.170519');
select openchpl.add_new_status(8430, '2018-04-04', '14.07.07.1221.POI2.11.01.1.170308');
select openchpl.add_new_status(8099, '2018-04-04', '14.07.07.1221.POI7.03.01.0.161012');
select openchpl.add_new_status(8387, '2018-04-04', '14.07.07.1221.POI5.11.01.1.170308');
select openchpl.add_new_status(9021, '2018-04-04', '14.07.07.1221.POA4.23.01.0.171206');
select openchpl.add_new_status(7754, '2018-04-04', '14.07.07.1221.CEA1.02.01.0.160502');
select openchpl.add_new_status(8759, '2018-04-04', '14.07.07.1221.FII1.18.01.1.170711');
select openchpl.add_new_status(8672, '2018-04-04', '14.07.07.1221.FIA4.11.01.0.170426');
select openchpl.add_new_status(8421, '2018-04-04', '14.07.07.1221.PAI3.08.01.1.170308');
select openchpl.add_new_status(8388, '2018-04-04', '14.07.07.1221.POA5.12.01.1.170308');
select openchpl.add_new_status(8886, '2018-04-04', '14.07.07.1221.PO08.15.01.1.171109');
select openchpl.add_new_status(8000, '2018-04-04', '14.07.07.1221.CEA1.09.01.0.160901');
select openchpl.add_new_status(8444, '2018-04-04', '14.07.07.1221.POI4.08.01.0.170308');
select openchpl.add_new_status(8158, '2018-04-04', '14.07.07.1221.PAA3.04.01.1.161108');
select openchpl.add_new_status(8649, '2018-04-04', '14.07.07.1221.POI2.16.01.1.170321');
select openchpl.add_new_status(8581, '2018-04-04', '14.07.07.1221.CEI1.19.01.0.170714');
select openchpl.add_new_status(7937, '2018-04-04', '14.03.07.1221.FII1.04.01.1.160711');
select openchpl.add_new_status(8666, '2018-04-04', '14.07.07.1221.POI2.17.01.1.170327');
select openchpl.add_new_status(7896, '2018-04-04', '14.03.07.1221.FII3.04.01.1.160711');
select openchpl.add_new_status(8436, '2018-04-04', '14.07.07.1221.HEI2.13.01.1.170308');
select openchpl.add_new_status(8424, '2018-04-04', '14.07.07.1221.POA1.11.01.1.170308');
select openchpl.add_new_status(8732, '2018-04-04', '14.07.07.1221.POA4.15.01.0.170608');
select openchpl.add_new_status(8710, '2018-04-04', '14.07.07.1221.HEA2.20.01.1.170519');
select openchpl.add_new_status(8386, '2018-04-04', '14.07.07.1221.POI5.10.01.1.170308');
select openchpl.add_new_status(8651, '2018-04-04', '14.07.07.1221.POI4.10.01.0.170321');
select openchpl.add_new_status(8401, '2018-04-04', '14.07.07.1221.HEA2.13.01.1.170308');
select openchpl.add_new_status(9134, '2018-04-04', '14.07.07.1221.PO04.22.01.0.171110');
select openchpl.add_new_status(8920, '2018-04-04', '14.07.07.1221.CE01.21.01.0.171109');
select openchpl.add_new_status(8162, '2018-04-04', '14.07.07.1221.FII4.04.01.0.161108');
select openchpl.add_new_status(7917, '2018-04-04', '14.03.07.1221.PAA3.01.01.1.160711');
select openchpl.add_new_status(8262, '2018-04-04', '14.07.07.1221.PAA3.04.01.1.161227');
select openchpl.add_new_status(8636, '2018-04-04', '14.07.07.1221.POA4.09.01.0.170320');
select openchpl.add_new_status(9128, '2018-04-04', '14.07.07.1221.CE01.20.01.0.171110');
select openchpl.add_new_status(7880, '2018-04-04', '14.03.07.1221.HEA3.04.01.1.160711');
select openchpl.add_new_status(8760, '2018-04-04', '14.07.07.1221.FII3.16.01.1.170711');
select openchpl.add_new_status(9122, '2018-04-04', '14.07.07.1221.PO08.15.01.0.171110');
select openchpl.add_new_status(8659, '2018-04-04', '14.07.07.1221.HEA2.17.01.1.170327');
select openchpl.add_new_status(7870, '2018-04-04', '14.03.07.1221.FIA4.04.01.0.160711');
select openchpl.add_new_status(7865, '2018-04-04', '14.03.07.1221.POI2.02.01.1.160711');
select openchpl.add_new_status(9035, '2018-04-04', '14.07.07.1221.FII4.22.01.0.171206');
select openchpl.add_new_status(8650, '2018-04-04', '14.07.07.1221.POI3.16.01.1.170321');
select openchpl.add_new_status(8740, '2018-04-04', '14.07.07.1221.FIA4.15.01.0.170705');
select openchpl.add_new_status(8981, '2018-04-04', '14.07.07.1221.CEA4.01.00.1.161228');
select openchpl.add_new_status(8682, '2018-04-04', '14.07.07.1221.POA5.18.01.1.170426');
select openchpl.add_new_status(8906, '2018-04-04', '14.07.07.1221.PO08.12.01.1.171109');
select openchpl.add_new_status(8003, '2018-04-04', '14.07.07.1221.CEA1.08.01.0.160901');
select openchpl.add_new_status(7926, '2018-04-04', '14.03.07.1221.FIA4.02.01.0.160711');
select openchpl.add_new_status(8383, '2018-04-04', '14.07.07.1221.HEA2.10.01.1.170308');
select openchpl.add_new_status(8261, '2018-04-04', '14.07.07.1221.PAI3.04.01.1.161227');
select openchpl.add_new_status(8297, '2018-04-04', '14.07.07.1221.CEI1.13.01.0.170116');
select openchpl.add_new_status(8439, '2018-04-04', '14.07.07.1221.HEA2.14.01.1.170308');
select openchpl.add_new_status(8773, '2018-04-04', '14.07.07.1221.POI3.23.01.1.170711');
select openchpl.add_new_status(7935, '2018-04-04', '14.03.07.1221.POI4.02.01.0.160711');
select openchpl.add_new_status(9044, '2018-04-04', '15.07.07.1221.SO05.01.01.1.171117');
select openchpl.add_new_status(7883, '2018-04-04', '14.03.07.1221.PAA3.02.01.1.160711');
select openchpl.add_new_status(8904, '2018-04-04', '14.07.07.1221.PO08.11.01.1.171109');
select openchpl.add_new_status(8403, '2018-04-04', '14.07.07.1221.HEA2.09.01.1.170308');
select openchpl.add_new_status(8431, '2018-04-04', '14.07.07.1221.POI3.10.01.1.170308');
select openchpl.add_new_status(7938, '2018-04-04', '14.03.07.1221.FII1.02.01.1.160711');
select openchpl.add_new_status(8164, '2018-04-04', '14.07.07.1221.POI4.04.01.0.161108');
select openchpl.add_new_status(8027, '2018-04-04', '14.07.07.1221.POA4.04.01.0.160906');
select openchpl.add_new_status(8426, '2018-04-04', '14.07.07.1221.POI2.10.01.1.170308');
select openchpl.add_new_status(7881, '2018-04-04', '14.03.07.1221.HEI3.04.01.1.160711');
select openchpl.add_new_status(7757, '2018-04-04', '14.07.07.1221.CEI1.04.01.0.160502');
select openchpl.add_new_status(7927, '2018-04-04', '14.03.07.1221.HEI3.02.01.1.160711');
select openchpl.add_new_status(9008, '2018-04-04', '14.07.07.1221.FIA4.23.01.0.171206');
select openchpl.add_new_status(7756, '2018-04-04', '14.07.07.1221.CEI1.02.01.0.160502');
select openchpl.add_new_status(9034, '2018-04-04', '14.07.07.1221.POI4.23.01.0.171206');
select openchpl.add_new_status(9037, '2018-04-04', '14.07.07.1221.POI8.17.01.0.171206');
select openchpl.add_new_status(8655, '2018-04-04', '14.07.07.1221.FIA4.10.01.0.170327');
select openchpl.add_new_status(8453, '2018-04-04', '14.07.07.1221.POI8.09.01.0.170313');
select openchpl.add_new_status(8701, '2018-04-04', '14.07.07.1221.POI3.19.01.1.170510');
select openchpl.add_new_status(8423, '2018-04-04', '14.07.07.1221.POA1.12.01.1.170308');
select openchpl.add_new_status(8392, '2018-04-04', '14.07.07.1221.POA5.11.01.1.170308');
select openchpl.add_new_status(8805, '2018-04-04', '14.07.07.1221.POI4.19.01.0.170728');
select openchpl.add_new_status(8750, '2018-04-04', '14.07.07.1221.POA4.16.01.0.170705');
select openchpl.add_new_status(7753, '2018-04-04', '14.07.07.1221.CEA1.01.01.0.160502');
select openchpl.add_new_status(8785, '2018-04-04', '14.07.07.1221.POA4.18.01.0.170727');
select openchpl.add_new_status(8714, '2018-04-04', '14.07.07.1221.HEI3.14.01.1.170519');
select openchpl.add_new_status(7923, '2018-04-04', '14.03.07.1221.POA4.02.01.0.160711');
select openchpl.add_new_status(8652, '2018-04-04', '14.07.07.1221.POI5.16.01.1.170321');
select openchpl.add_new_status(8394, '2018-04-04', '14.07.07.1221.POA5.10.01.1.170308');
select openchpl.add_new_status(9145, '2018-04-04', '14.07.07.1221.PO04.21.01.0.171110');
select openchpl.add_new_status(8400, '2018-04-04', '14.07.07.1221.HEI2.10.01.1.170308');
select openchpl.add_new_status(7897, '2018-04-04', '14.03.07.1221.HEA2.04.01.1.160711');
select openchpl.add_new_status(8093, '2018-04-04', '14.07.07.1221.POA6.04.01.1.161012');
select openchpl.add_new_status(7866, '2018-04-04', '14.03.07.1221.POA4.03.01.0.160711');
select openchpl.add_new_status(7888, '2018-04-04', '14.03.07.1221.FIA2.02.01.1.160711');
select openchpl.add_new_status(8801, '2018-04-04', '14.07.07.1221.POA4.19.01.0.170728');
select openchpl.add_new_status(8451, '2018-04-04', '14.07.07.1221.CEA1.15.01.0.170310');
select openchpl.add_new_status(8737, '2018-04-04', '14.07.07.1221.POI5.21.01.1.170608');
select openchpl.add_new_status(7934, '2018-04-04', '14.03.07.1221.HEA3.02.01.1.160711');
select openchpl.add_new_status(8585, '2018-04-04', '14.07.07.1221.CEI1.17.01.0.170721');
select openchpl.add_new_status(8717, '2018-04-04', '14.07.07.1221.POI2.20.01.1.170519');
select openchpl.add_new_status(8428, '2018-04-04', '14.07.07.1221.POI5.09.01.1.170308');
select openchpl.add_new_status(8765, '2018-04-04', '14.07.07.1221.HEI3.17.01.1.170711');
select openchpl.add_new_status(8443, '2018-04-04', '14.07.07.1221.HEI2.14.01.1.170308');
select openchpl.add_new_status(8734, '2018-04-04', '14.07.07.1221.POI2.21.01.1.170608');
select openchpl.add_new_status(7931, '2018-04-04', '14.03.07.1221.POI4.03.01.0.160711');
select openchpl.add_new_status(8718, '2018-04-04', '14.07.07.1221.POI3.20.01.1.170519');
select openchpl.add_new_status(8708, '2018-04-04', '14.07.07.1221.FII3.13.01.1.170519');
select openchpl.add_new_status(9125, '2018-04-04', '14.07.07.1221.PO08.13.01.0.171110');
select openchpl.add_new_status(8279, '2018-04-04', '14.07.07.1221.POI4.04.01.0.161227');
select openchpl.add_new_status(8736, '2018-04-04', '14.07.07.1221.POI4.15.01.0.170608');
select openchpl.add_new_status(7924, '2018-04-04', '14.03.07.1221.FII4.02.01.0.160711');
select openchpl.add_new_status(8459, '2018-04-04', '14.07.07.1221.POA8.10.01.1.170313');
select openchpl.add_new_status(8769, '2018-04-04', '14.07.07.1221.POI4.17.01.0.170711');
select openchpl.add_new_status(8446, '2018-04-04', '14.07.07.1221.HEI3.09.01.1.170308');
select openchpl.add_new_status(8419, '2018-04-04', '14.07.07.1221.FIA4.08.01.0.170308');
select openchpl.add_new_status(8683, '2018-04-04', '14.07.07.1221.POI2.18.01.1.170426');
select openchpl.add_new_status(8772, '2018-04-04', '14.07.07.1221.POI2.23.01.1.170711');
select openchpl.add_new_status(8725, '2018-04-04', '14.07.07.1221.FII3.14.01.1.170608');
select openchpl.add_new_status(8685, '2018-04-04', '14.07.07.1221.POI4.12.01.0.170426');
select openchpl.add_new_status(7997, '2018-04-04', '14.07.07.1221.CEA1.07.01.0.160901');
select openchpl.add_new_status(8676, '2018-04-04', '14.07.07.1221.HEA2.18.01.1.170426');
select openchpl.add_new_status(8425, '2018-04-04', '14.07.07.1221.POI2.12.01.1.170308');
select openchpl.add_new_status(8702, '2018-04-04', '14.07.07.1221.POI4.13.01.0.170510');
select openchpl.add_new_status(8681, '2018-04-04', '14.07.07.1221.POA4.12.01.0.170426');
select openchpl.add_new_status(8101, '2018-04-04', '14.07.07.1221.POA6.02.01.1.161012');
select openchpl.add_new_status(7994, '2018-04-04', '14.07.07.1221.CEA1.06.01.0.160901');
select openchpl.add_new_status(8310, '2018-04-04', '14.07.07.1221.POA8.06.01.1.170120');
select openchpl.add_new_status(8915, '2018-04-04', '14.07.07.1221.PO04.22.01.0.171109');
select openchpl.add_new_status(8899, '2018-04-04', '14.07.07.1221.PA03.11.01.1.171109');
select openchpl.add_new_status(7878, '2018-04-04', '14.03.07.1221.POI5.04.01.1.160711');
select openchpl.add_new_status(8926, '2018-04-04', '14.07.07.1221.PA03.11.01.1.171110');
select openchpl.add_new_status(8770, '2018-04-04', '14.07.07.1221.POI5.23.01.1.170711');
select openchpl.add_new_status(8450, '2018-04-04', '14.07.07.1221.CEI1.15.01.0.170310');
select openchpl.add_new_status(9018, '2018-04-04', '14.07.07.1221.POA8.17.01.1.171206');
select openchpl.add_new_status(8688, '2018-04-04', '14.07.07.1221.FIA2.13.01.1.170510');
select openchpl.add_new_status(8390, '2018-04-04', '14.07.07.1221.POA5.13.01.1.170308');
select openchpl.add_new_status(8398, '2018-04-04', '14.07.07.1221.HEA3.09.01.1.170308');
select openchpl.add_new_status(8647, '2018-04-04', '14.07.07.1221.POA4.10.01.0.170321');
select openchpl.add_new_status(9126, '2018-04-04', '14.07.07.1221.PO08.14.01.0.171110');
select openchpl.add_new_status(8938, '2018-04-04', '14.07.07.1221.FI04.20.01.0.171110');
select openchpl.add_new_status(8654, '2018-04-04', '14.07.07.1221.FIA2.11.01.1.170327');
select openchpl.add_new_status(8448, '2018-04-04', '14.07.07.1221.CEA1.14.01.0.170310');
select openchpl.add_new_status(8433, '2018-04-04', '14.07.07.1221.POI3.13.01.1.170308');
select openchpl.add_new_status(8678, '2018-04-04', '14.07.07.1221.HEI2.18.01.1.170426');
select openchpl.add_new_status(7901, '2018-04-04', '14.03.07.1221.HEI2.04.01.1.160711');
select openchpl.add_new_status(8396, '2018-04-04', '14.07.07.1221.POA5.14.01.1.170308');
select openchpl.add_new_status(8699, '2018-04-04', '14.07.07.1221.POA5.19.01.1.170510');
select openchpl.add_new_status(8743, '2018-04-04', '14.07.07.1221.FII4.15.01.0.170705');
select openchpl.add_new_status(8452, '2018-04-04', '14.07.07.1221.CEI1.14.01.0.170310');
select openchpl.add_new_status(8730, '2018-04-04', '14.07.07.1221.HEI3.15.01.1.170608');
select openchpl.add_new_status(8808, '2018-04-04', '14.07.07.1221.PAA3.09.01.1.170320');
select openchpl.add_new_status(8673, '2018-04-04', '14.07.07.1221.FII1.13.01.1.170426');
select openchpl.add_new_status(9028, '2018-04-04', '14.07.07.1221.CEI4.02.00.1.171206');
select openchpl.add_new_status(9046, '2018-04-04', '15.07.07.1221.PO05.08.01.1.171117');
select openchpl.add_new_status(8023, '2018-04-04', '14.07.07.1221.FIA4.04.01.0.160906');
select openchpl.add_new_status(6558, '2018-04-04', 'CHP-021865');
select openchpl.add_new_status(6552, '2018-04-04', 'CHP-021869');
select openchpl.add_new_status(7599, '2018-04-04', 'CHP-028502');
select openchpl.add_new_status(7458, '2018-04-04', 'CHP-029001');
select openchpl.add_new_status(7459, '2018-04-04', 'CHP-029002');
select openchpl.add_new_status(7461, '2018-04-04', 'CHP-029004');
select openchpl.add_new_status(6040, '2018-04-04', 'CHP-023326');
select openchpl.add_new_status(6058, '2018-04-04', 'CHP-023332');
select openchpl.add_new_status(5868, '2018-04-04', 'CHP-021711');
select openchpl.add_new_status(7651, '2018-04-04', 'CHP-021923');
select openchpl.add_new_status(7652, '2018-04-04', 'CHP-021924');
select openchpl.add_new_status(7653, '2018-04-04', 'CHP-021925');
select openchpl.add_new_status(7655, '2018-04-04', 'CHP-021926');
select openchpl.add_new_status(7656, '2018-04-04', 'CHP-021927');
select openchpl.add_new_status(7657, '2018-04-04', 'CHP-021928');
select openchpl.add_new_status(7658, '2018-04-04', 'CHP-021929');
select openchpl.add_new_status(7660, '2018-04-04', 'CHP-021930');
select openchpl.add_new_status(7661, '2018-04-04', 'CHP-021931');
select openchpl.add_new_status(7663, '2018-04-04', 'CHP-021933');
select openchpl.add_new_status(7665, '2018-04-04', 'CHP-021934');
select openchpl.add_new_status(7666, '2018-04-04', 'CHP-021935');
select openchpl.add_new_status(7669, '2018-04-04', 'CHP-021937');
select openchpl.add_new_status(7670, '2018-04-04', 'CHP-021938');
select openchpl.add_new_status(7672, '2018-04-04', 'CHP-021939');
select openchpl.add_new_status(7673, '2018-04-04', 'CHP-021940');
select openchpl.add_new_status(7674, '2018-04-04', 'CHP-021941');
select openchpl.add_new_status(7675, '2018-04-04', 'CHP-021942');
select openchpl.add_new_status(7676, '2018-04-04', 'CHP-021943');
select openchpl.add_new_status(7677, '2018-04-04', 'CHP-021944');
select openchpl.add_new_status(7682, '2018-04-04', 'CHP-021946');
select openchpl.add_new_status(7683, '2018-04-04', 'CHP-021947');
select openchpl.add_new_status(7684, '2018-04-04', 'CHP-021948');
select openchpl.add_new_status(7685, '2018-04-04', 'CHP-021949');
select openchpl.add_new_status(7686, '2018-04-04', 'CHP-021950');
select openchpl.add_new_status(7687, '2018-04-04', 'CHP-021951');
select openchpl.add_new_status(7688, '2018-04-04', 'CHP-021952');
select openchpl.add_new_status(7649, '2018-04-04', 'CHP-021955');
select openchpl.add_new_status(7650, '2018-04-04', 'CHP-021956');
select openchpl.add_new_status(7654, '2018-04-04', 'CHP-021957');
select openchpl.add_new_status(7659, '2018-04-04', 'CHP-021958');
select openchpl.add_new_status(7679, '2018-04-04', 'CHP-021960');
select openchpl.add_new_status(6512, '2018-04-04', 'CHP-022085');
select openchpl.add_new_status(6514, '2018-04-04', 'CHP-022086');
select openchpl.add_new_status(6516, '2018-04-04', 'CHP-022087');
select openchpl.add_new_status(6520, '2018-04-04', 'CHP-022089');
select openchpl.add_new_status(6522, '2018-04-04', 'CHP-022090');
select openchpl.add_new_status(6524, '2018-04-04', 'CHP-022091');
select openchpl.add_new_status(6526, '2018-04-04', 'CHP-022092');
select openchpl.add_new_status(6528, '2018-04-04', 'CHP-022093');
select openchpl.add_new_status(6530, '2018-04-04', 'CHP-022094');
select openchpl.add_new_status(6532, '2018-04-04', 'CHP-022095');
select openchpl.add_new_status(7460, '2018-04-04', 'CHP-029003');
select openchpl.add_new_status(7462, '2018-04-04', 'CHP-029005');
select openchpl.add_new_status(7262, '2018-04-04', 'CHP-022113');
select openchpl.add_new_status(7263, '2018-04-04', 'CHP-022114');
select openchpl.add_new_status(7264, '2018-04-04', 'CHP-022115');
select openchpl.add_new_status(7600, '2018-04-04', 'CHP-028503');
select openchpl.add_new_status(7601, '2018-04-04', 'CHP-028504');
select openchpl.add_new_status(6160, '2018-04-04', 'CHP-022478');
select openchpl.add_new_status(6163, '2018-04-04', 'CHP-022479');
select openchpl.add_new_status(7602, '2018-04-04', 'CHP-028505');
select openchpl.add_new_status(6220, '2018-04-04', 'CHP-022549');
select openchpl.add_new_status(6223, '2018-04-04', 'CHP-022550');
select openchpl.add_new_status(6232, '2018-04-04', 'CHP-022555');
select openchpl.add_new_status(6235, '2018-04-04', 'CHP-022556');
select openchpl.add_new_status(6238, '2018-04-04', 'CHP-022557');
select openchpl.add_new_status(6241, '2018-04-04', 'CHP-022558');
select openchpl.add_new_status(6244, '2018-04-04', 'CHP-022559');
select openchpl.add_new_status(6246, '2018-04-04', 'CHP-022560');
select openchpl.add_new_status(6248, '2018-04-04', 'CHP-022561');
select openchpl.add_new_status(6250, '2018-04-04', 'CHP-022562');
select openchpl.add_new_status(6252, '2018-04-04', 'CHP-022563');
select openchpl.add_new_status(6254, '2018-04-04', 'CHP-022564');
select openchpl.add_new_status(7312, '2018-04-04', 'CHP-022836');
select openchpl.add_new_status(6842, '2018-04-04', 'CHP-023081');
select openchpl.add_new_status(6843, '2018-04-04', 'CHP-023082');
select openchpl.add_new_status(6844, '2018-04-04', 'CHP-023083');
select openchpl.add_new_status(5992, '2018-04-04', 'CHP-023127');
select openchpl.add_new_status(5929, '2018-04-04', 'CHP-023117');
select openchpl.add_new_status(5932, '2018-04-04', 'CHP-023118');
select openchpl.add_new_status(5935, '2018-04-04', 'CHP-023119');
select openchpl.add_new_status(5956, '2018-04-04', 'CHP-023120');
select openchpl.add_new_status(5959, '2018-04-04', 'CHP-023121');
select openchpl.add_new_status(5962, '2018-04-04', 'CHP-023122');
select openchpl.add_new_status(5965, '2018-04-04', 'CHP-023123');
select openchpl.add_new_status(5971, '2018-04-04', 'CHP-023125');
select openchpl.add_new_status(5980, '2018-04-04', 'CHP-023316');
select openchpl.add_new_status(6007, '2018-04-04', 'CHP-023126');
select openchpl.add_new_status(5995, '2018-04-04', 'CHP-023128');
select openchpl.add_new_status(5998, '2018-04-04', 'CHP-023129');
select openchpl.add_new_status(6001, '2018-04-04', 'CHP-023130');
select openchpl.add_new_status(6004, '2018-04-04', 'CHP-023131');
select openchpl.add_new_status(6028, '2018-04-04', 'CHP-023132');
select openchpl.add_new_status(6031, '2018-04-04', 'CHP-023133');
select openchpl.add_new_status(6034, '2018-04-04', 'CHP-023134');
select openchpl.add_new_status(6037, '2018-04-04', 'CHP-023135');
select openchpl.add_new_status(6280, '2018-04-04', 'CHP-023190');
select openchpl.add_new_status(6284, '2018-04-04', 'CHP-023192');
select openchpl.add_new_status(6288, '2018-04-04', 'CHP-023194');
select openchpl.add_new_status(6290, '2018-04-04', 'CHP-023195');
select openchpl.add_new_status(6292, '2018-04-04', 'CHP-023196');
select openchpl.add_new_status(6294, '2018-04-04', 'CHP-023197');
select openchpl.add_new_status(6166, '2018-04-04', 'CHP-023222');
select openchpl.add_new_status(6172, '2018-04-04', 'CHP-023224');
select openchpl.add_new_status(6175, '2018-04-04', 'CHP-023225');
select openchpl.add_new_status(6178, '2018-04-04', 'CHP-023226');
select openchpl.add_new_status(6181, '2018-04-04', 'CHP-023227');
select openchpl.add_new_status(6184, '2018-04-04', 'CHP-023228');
select openchpl.add_new_status(6187, '2018-04-04', 'CHP-023229');
select openchpl.add_new_status(6190, '2018-04-04', 'CHP-023230');
select openchpl.add_new_status(6193, '2018-04-04', 'CHP-023231');
select openchpl.add_new_status(6196, '2018-04-04', 'CHP-023232');
select openchpl.add_new_status(5950, '2018-04-04', 'CHP-023312');
select openchpl.add_new_status(5953, '2018-04-04', 'CHP-023313');
select openchpl.add_new_status(5977, '2018-04-04', 'CHP-023315');
select openchpl.add_new_status(5983, '2018-04-04', 'CHP-023317');
select openchpl.add_new_status(5986, '2018-04-04', 'CHP-023318');
select openchpl.add_new_status(5989, '2018-04-04', 'CHP-023319');
select openchpl.add_new_status(6010, '2018-04-04', 'CHP-023320');
select openchpl.add_new_status(6016, '2018-04-04', 'CHP-023322');
select openchpl.add_new_status(6019, '2018-04-04', 'CHP-023323');
select openchpl.add_new_status(6022, '2018-04-04', 'CHP-023324');
select openchpl.add_new_status(6025, '2018-04-04', 'CHP-023325');
select openchpl.add_new_status(6043, '2018-04-04', 'CHP-023327');
select openchpl.add_new_status(6049, '2018-04-04', 'CHP-023329');
select openchpl.add_new_status(6052, '2018-04-04', 'CHP-023330');
select openchpl.add_new_status(6055, '2018-04-04', 'CHP-023331');
select openchpl.add_new_status(6061, '2018-04-04', 'CHP-023333');
select openchpl.add_new_status(6064, '2018-04-04', 'CHP-023334');
select openchpl.add_new_status(7124, '2018-04-04', 'CHP-019789');
select openchpl.add_new_status(5571, '2018-04-04', 'CHP-024988');
select openchpl.add_new_status(7343, '2018-04-04', 'CHP-023590');
select openchpl.add_new_status(7345, '2018-04-04', 'CHP-023591');
select openchpl.add_new_status(5975, '2018-04-04', 'CHP-024944');
select openchpl.add_new_status(5876, '2018-04-04', 'CHP-024945');
select openchpl.add_new_status(5579, '2018-04-04', 'CHP-024990');
select openchpl.add_new_status(6605, '2018-04-04', 'CHP-023638');
select openchpl.add_new_status(6611, '2018-04-04', 'CHP-023639');
select openchpl.add_new_status(6607, '2018-04-04', 'CHP-023640');
select openchpl.add_new_status(6641, '2018-04-04', 'CHP-023656');
select openchpl.add_new_status(6645, '2018-04-04', 'CHP-023657');
select openchpl.add_new_status(6651, '2018-04-04', 'CHP-023661');
select openchpl.add_new_status(6659, '2018-04-04', 'CHP-023665');
select openchpl.add_new_status(6665, '2018-04-04', 'CHP-023668');
select openchpl.add_new_status(6667, '2018-04-04', 'CHP-023669');
select openchpl.add_new_status(6673, '2018-04-04', 'CHP-023670');
select openchpl.add_new_status(6669, '2018-04-04', 'CHP-023671');
select openchpl.add_new_status(6671, '2018-04-04', 'CHP-023672');
select openchpl.add_new_status(6675, '2018-04-04', 'CHP-023673');
select openchpl.add_new_status(6677, '2018-04-04', 'CHP-023674');
select openchpl.add_new_status(6679, '2018-04-04', 'CHP-023675');
select openchpl.add_new_status(6599, '2018-04-04', 'CHP-023676');
select openchpl.add_new_status(6584, '2018-04-04', 'CHP-023850');
select openchpl.add_new_status(6588, '2018-04-04', 'CHP-023852');
select openchpl.add_new_status(6590, '2018-04-04', 'CHP-023853');
select openchpl.add_new_status(6592, '2018-04-04', 'CHP-023854');
select openchpl.add_new_status(6596, '2018-04-04', 'CHP-023856');
select openchpl.add_new_status(6598, '2018-04-04', 'CHP-023857');
select openchpl.add_new_status(6600, '2018-04-04', 'CHP-023858');
select openchpl.add_new_status(6602, '2018-04-04', 'CHP-023859');
select openchpl.add_new_status(6604, '2018-04-04', 'CHP-023860');
select openchpl.add_new_status(6606, '2018-04-04', 'CHP-023861');
select openchpl.add_new_status(6608, '2018-04-04', 'CHP-023862');
select openchpl.add_new_status(6610, '2018-04-04', 'CHP-023863');
select openchpl.add_new_status(6626, '2018-04-04', 'CHP-023871');
select openchpl.add_new_status(6382, '2018-04-04', 'CHP-023939');
select openchpl.add_new_status(5861, '2018-04-04', 'CHP-023995');
select openchpl.add_new_status(5789, '2018-04-04', 'CHP-024021');
select openchpl.add_new_status(5795, '2018-04-04', 'CHP-024023');
select openchpl.add_new_status(5816, '2018-04-04', 'CHP-024030');
select openchpl.add_new_status(6491, '2018-04-04', 'CHP-025025');
select openchpl.add_new_status(6005, '2018-04-04', 'CHP-024150');
select openchpl.add_new_status(6008, '2018-04-04', 'CHP-024151');
select openchpl.add_new_status(6011, '2018-04-04', 'CHP-024152');
select openchpl.add_new_status(6014, '2018-04-04', 'CHP-024153');
select openchpl.add_new_status(6017, '2018-04-04', 'CHP-024154');
select openchpl.add_new_status(6020, '2018-04-04', 'CHP-024155');
select openchpl.add_new_status(6023, '2018-04-04', 'CHP-024156');
select openchpl.add_new_status(6032, '2018-04-04', 'CHP-024159');
select openchpl.add_new_status(6035, '2018-04-04', 'CHP-024160');
select openchpl.add_new_status(6038, '2018-04-04', 'CHP-024161');
select openchpl.add_new_status(6041, '2018-04-04', 'CHP-024162');
select openchpl.add_new_status(6065, '2018-04-04', 'CHP-024170');
select openchpl.add_new_status(6068, '2018-04-04', 'CHP-024171');
select openchpl.add_new_status(6071, '2018-04-04', 'CHP-024172');
select openchpl.add_new_status(6074, '2018-04-04', 'CHP-024173');
select openchpl.add_new_status(6323, '2018-04-04', 'CHP-025273');
select openchpl.add_new_status(6077, '2018-04-04', 'CHP-024174');
select openchpl.add_new_status(6080, '2018-04-04', 'CHP-024175');
select openchpl.add_new_status(6083, '2018-04-04', 'CHP-024176');
select openchpl.add_new_status(6335, '2018-04-04', 'CHP-025279');
select openchpl.add_new_status(5639, '2018-04-04', 'CHP-024240');
select openchpl.add_new_status(6343, '2018-04-04', 'CHP-025283');
select openchpl.add_new_status(5681, '2018-04-04', 'CHP-024254');
select openchpl.add_new_status(7217, '2018-04-04', 'CHP-028541');
select openchpl.add_new_status(6903, '2018-04-04', 'CHP-025365');
select openchpl.add_new_status(6521, '2018-04-04', 'CHP-024459');
select openchpl.add_new_status(6523, '2018-04-04', 'CHP-024460');
select openchpl.add_new_status(7287, '2018-04-04', 'CHP-025388');
select openchpl.add_new_status(7288, '2018-04-04', 'CHP-025389');
select openchpl.add_new_status(7296, '2018-04-04', 'CHP-025393');
select openchpl.add_new_status(5683, '2018-04-04', 'CHP-025461');
select openchpl.add_new_status(5510, '2018-04-04', 'CHP-025483');
select openchpl.add_new_status(6265, '2018-04-04', 'CHP-024694');
select openchpl.add_new_status(6267, '2018-04-04', 'CHP-024695');
select openchpl.add_new_status(6269, '2018-04-04', 'CHP-024696');
select openchpl.add_new_status(6271, '2018-04-04', 'CHP-024697');
select openchpl.add_new_status(6273, '2018-04-04', 'CHP-024698');
select openchpl.add_new_status(6275, '2018-04-04', 'CHP-024699');
select openchpl.add_new_status(6143, '2018-04-04', 'CHP-024700');
select openchpl.add_new_status(6146, '2018-04-04', 'CHP-024701');
select openchpl.add_new_status(6149, '2018-04-04', 'CHP-024702');
select openchpl.add_new_status(6152, '2018-04-04', 'CHP-024703');
select openchpl.add_new_status(6155, '2018-04-04', 'CHP-024704');
select openchpl.add_new_status(6158, '2018-04-04', 'CHP-024705');
select openchpl.add_new_status(6161, '2018-04-04', 'CHP-024706');
select openchpl.add_new_status(6164, '2018-04-04', 'CHP-024707');
select openchpl.add_new_status(6167, '2018-04-04', 'CHP-024708');
select openchpl.add_new_status(6170, '2018-04-04', 'CHP-024709');
select openchpl.add_new_status(6173, '2018-04-04', 'CHP-024710');
select openchpl.add_new_status(6176, '2018-04-04', 'CHP-024711');
select openchpl.add_new_status(6179, '2018-04-04', 'CHP-024712');
select openchpl.add_new_status(6182, '2018-04-04', 'CHP-024713');
select openchpl.add_new_status(6185, '2018-04-04', 'CHP-024714');
select openchpl.add_new_status(6188, '2018-04-04', 'CHP-024715');
select openchpl.add_new_status(6191, '2018-04-04', 'CHP-024716');
select openchpl.add_new_status(6200, '2018-04-04', 'CHP-024719');
select openchpl.add_new_status(6206, '2018-04-04', 'CHP-024721');
select openchpl.add_new_status(6212, '2018-04-04', 'CHP-024723');
select openchpl.add_new_status(6215, '2018-04-04', 'CHP-024724');
select openchpl.add_new_status(6218, '2018-04-04', 'CHP-024725');
select openchpl.add_new_status(6221, '2018-04-04', 'CHP-024726');
select openchpl.add_new_status(6224, '2018-04-04', 'CHP-024727');
select openchpl.add_new_status(6227, '2018-04-04', 'CHP-024728');
select openchpl.add_new_status(6230, '2018-04-04', 'CHP-024729');
select openchpl.add_new_status(6233, '2018-04-04', 'CHP-024730');
select openchpl.add_new_status(6236, '2018-04-04', 'CHP-024731');
select openchpl.add_new_status(6239, '2018-04-04', 'CHP-024732');
select openchpl.add_new_status(6242, '2018-04-04', 'CHP-024733');
select openchpl.add_new_status(6251, '2018-04-04', 'CHP-024737');
select openchpl.add_new_status(6253, '2018-04-04', 'CHP-024738');
select openchpl.add_new_status(6255, '2018-04-04', 'CHP-024739');
select openchpl.add_new_status(6614, '2018-04-04', 'CHP-023865');
select openchpl.add_new_status(6616, '2018-04-04', 'CHP-023866');
select openchpl.add_new_status(6620, '2018-04-04', 'CHP-023868');
select openchpl.add_new_status(6630, '2018-04-04', 'CHP-023873');
select openchpl.add_new_status(6634, '2018-04-04', 'CHP-023875');
select openchpl.add_new_status(6704, '2018-04-04', 'CHP-023877');
select openchpl.add_new_status(7485, '2018-04-04', 'CHP-028302');
select openchpl.add_new_status(7207, '2018-04-04', 'CHP-028566');
select openchpl.add_new_status(7173, '2018-04-04', 'CHP-028576');
select openchpl.add_new_status(6249, '2018-04-04', 'CHP-024736');
select openchpl.add_new_status(5906, '2018-04-04', 'CHP-024955');
select openchpl.add_new_status(7482, '2018-04-04', 'CHP-028299');
select openchpl.add_new_status(7483, '2018-04-04', 'CHP-028300');
select openchpl.add_new_status(7484, '2018-04-04', 'CHP-028301');
select openchpl.add_new_status(7486, '2018-04-04', 'CHP-028303');
select openchpl.add_new_status(5909, '2018-04-04', 'CHP-024956');
select openchpl.add_new_status(7487, '2018-04-04', 'CHP-028304');
select openchpl.add_new_status(5882, '2018-04-04', 'CHP-024947');
select openchpl.add_new_status(5885, '2018-04-04', 'CHP-024948');
select openchpl.add_new_status(5888, '2018-04-04', 'CHP-024949');
select openchpl.add_new_status(5891, '2018-04-04', 'CHP-024950');
select openchpl.add_new_status(5894, '2018-04-04', 'CHP-024951');
select openchpl.add_new_status(5897, '2018-04-04', 'CHP-024952');
select openchpl.add_new_status(5900, '2018-04-04', 'CHP-024953');
select openchpl.add_new_status(5903, '2018-04-04', 'CHP-024954');
select openchpl.add_new_status(5912, '2018-04-04', 'CHP-024957');
select openchpl.add_new_status(5921, '2018-04-04', 'CHP-024959');
select openchpl.add_new_status(5930, '2018-04-04', 'CHP-024962');
select openchpl.add_new_status(5933, '2018-04-04', 'CHP-024963');
select openchpl.add_new_status(5936, '2018-04-04', 'CHP-024964');
select openchpl.add_new_status(5942, '2018-04-04', 'CHP-024966');
select openchpl.add_new_status(5948, '2018-04-04', 'CHP-024968');
select openchpl.add_new_status(5927, '2018-04-04', 'CHP-024961');
select openchpl.add_new_status(7144, '2018-04-04', 'CHP-020918');
select openchpl.add_new_status(7150, '2018-04-04', 'CHP-020924');
select openchpl.add_new_status(6156, '2018-04-04', 'CHP-021129');
select openchpl.add_new_status(5463, '2018-04-04', 'CHP-021406');
select openchpl.add_new_status(5439, '2018-04-04', 'CHP-021412');
select openchpl.add_new_status(6438, '2018-04-04', 'CHP-021666');
select openchpl.add_new_status(6440, '2018-04-04', 'CHP-021667');
select openchpl.add_new_status(6432, '2018-04-04', 'CHP-021674');
select openchpl.add_new_status(6448, '2018-04-04', 'CHP-021677');
select openchpl.add_new_status(5871, '2018-04-04', 'CHP-021712');
select openchpl.add_new_status(5877, '2018-04-04', 'CHP-021714');
select openchpl.add_new_status(7560, '2018-04-04', 'CHP-021739');
select openchpl.add_new_status(6560, '2018-04-04', 'CHP-021866');
select openchpl.add_new_status(6548, '2018-04-04', 'CHP-021867');
select openchpl.add_new_status(6564, '2018-04-04', 'CHP-021876');
select openchpl.add_new_status(7678, '2018-04-04', 'CHP-021945');
select openchpl.add_new_status(7648, '2018-04-04', 'CHP-021953');
select openchpl.add_new_status(6518, '2018-04-04', 'CHP-022088');
select openchpl.add_new_status(6229, '2018-04-04', 'CHP-022554');
select openchpl.add_new_status(6643, '2018-04-04', 'CHP-023660');
select openchpl.add_new_status(6835, '2018-04-04', 'CHP-023074');
select openchpl.add_new_status(6839, '2018-04-04', 'CHP-023078');
select openchpl.add_new_status(5968, '2018-04-04', 'CHP-023124');
select openchpl.add_new_status(6278, '2018-04-04', 'CHP-023189');
select openchpl.add_new_status(6282, '2018-04-04', 'CHP-023191');
select openchpl.add_new_status(6169, '2018-04-04', 'CHP-023223');
select openchpl.add_new_status(6013, '2018-04-04', 'CHP-023321');
select openchpl.add_new_status(6046, '2018-04-04', 'CHP-023328');
select openchpl.add_new_status(6661, '2018-04-04', 'CHP-023666');
select openchpl.add_new_status(6601, '2018-04-04', 'CHP-023677');
select openchpl.add_new_status(6612, '2018-04-04', 'CHP-023864');
select openchpl.add_new_status(6624, '2018-04-04', 'CHP-023870');
select openchpl.add_new_status(6632, '2018-04-04', 'CHP-023874');
select openchpl.add_new_status(6026, '2018-04-04', 'CHP-024157');
select openchpl.add_new_status(5684, '2018-04-04', 'CHP-024744');
select openchpl.add_new_status(5879, '2018-04-04', 'CHP-024946');
select openchpl.add_new_status(5915, '2018-04-04', 'CHP-024958');
select openchpl.add_new_status(5924, '2018-04-04', 'CHP-024960');
select openchpl.add_new_status(6505, '2018-04-04', 'CHP-025007');
select openchpl.add_new_status(6507, '2018-04-04', 'CHP-025008');
select openchpl.add_new_status(6509, '2018-04-04', 'CHP-025009');
select openchpl.add_new_status(6461, '2018-04-04', 'CHP-025010');
select openchpl.add_new_status(6463, '2018-04-04', 'CHP-025011');
select openchpl.add_new_status(6465, '2018-04-04', 'CHP-025012');
select openchpl.add_new_status(6467, '2018-04-04', 'CHP-025013');
select openchpl.add_new_status(6469, '2018-04-04', 'CHP-025014');
select openchpl.add_new_status(6471, '2018-04-04', 'CHP-025015');
select openchpl.add_new_status(6477, '2018-04-04', 'CHP-025018');
select openchpl.add_new_status(6479, '2018-04-04', 'CHP-025019');
select openchpl.add_new_status(6481, '2018-04-04', 'CHP-025020');
select openchpl.add_new_status(6483, '2018-04-04', 'CHP-025021');
select openchpl.add_new_status(6485, '2018-04-04', 'CHP-025022');
select openchpl.add_new_status(6487, '2018-04-04', 'CHP-025023');
select openchpl.add_new_status(6489, '2018-04-04', 'CHP-025024');
select openchpl.add_new_status(6493, '2018-04-04', 'CHP-025026');
select openchpl.add_new_status(6495, '2018-04-04', 'CHP-025027');
select openchpl.add_new_status(6497, '2018-04-04', 'CHP-025028');
select openchpl.add_new_status(6499, '2018-04-04', 'CHP-025029');
select openchpl.add_new_status(6911, '2018-04-04', 'CHP-025367');
select openchpl.add_new_status(7269, '2018-04-04', 'CHP-025100');
select openchpl.add_new_status(5626, '2018-04-04', 'CHP-025442');
select openchpl.add_new_status(7376, '2018-04-04', 'CHP-025158');
select openchpl.add_new_status(7377, '2018-04-04', 'CHP-025159');
select openchpl.add_new_status(7378, '2018-04-04', 'CHP-025160');
select openchpl.add_new_status(7379, '2018-04-04', 'CHP-025161');
select openchpl.add_new_status(7380, '2018-04-04', 'CHP-025162');
select openchpl.add_new_status(7381, '2018-04-04', 'CHP-025163');
select openchpl.add_new_status(7387, '2018-04-04', 'CHP-025164');
select openchpl.add_new_status(7388, '2018-04-04', 'CHP-025165');
select openchpl.add_new_status(7349, '2018-04-04', 'CHP-025170');
select openchpl.add_new_status(7352, '2018-04-04', 'CHP-025173');
select openchpl.add_new_status(7355, '2018-04-04', 'CHP-025176');
select openchpl.add_new_status(7356, '2018-04-04', 'CHP-025177');
select openchpl.add_new_status(7357, '2018-04-04', 'CHP-025178');
select openchpl.add_new_status(7361, '2018-04-04', 'CHP-025182');
select openchpl.add_new_status(7362, '2018-04-04', 'CHP-025183');
select openchpl.add_new_status(7363, '2018-04-04', 'CHP-025184');
select openchpl.add_new_status(7364, '2018-04-04', 'CHP-025185');
select openchpl.add_new_status(7365, '2018-04-04', 'CHP-025186');
select openchpl.add_new_status(7366, '2018-04-04', 'CHP-025187');
select openchpl.add_new_status(7367, '2018-04-04', 'CHP-025188');
select openchpl.add_new_status(7368, '2018-04-04', 'CHP-025189');
select openchpl.add_new_status(7369, '2018-04-04', 'CHP-025190');
select openchpl.add_new_status(7370, '2018-04-04', 'CHP-025191');
select openchpl.add_new_status(5629, '2018-04-04', 'CHP-025443');
select openchpl.add_new_status(7371, '2018-04-04', 'CHP-025192');
select openchpl.add_new_status(7372, '2018-04-04', 'CHP-025193');
select openchpl.add_new_status(7373, '2018-04-04', 'CHP-025194');
select openchpl.add_new_status(7374, '2018-04-04', 'CHP-025195');
select openchpl.add_new_status(7375, '2018-04-04', 'CHP-025196');
select openchpl.add_new_status(7382, '2018-04-04', 'CHP-025197');
select openchpl.add_new_status(7383, '2018-04-04', 'CHP-025198');
select openchpl.add_new_status(7384, '2018-04-04', 'CHP-025199');
select openchpl.add_new_status(7385, '2018-04-04', 'CHP-025200');
select openchpl.add_new_status(7386, '2018-04-04', 'CHP-025201');
select openchpl.add_new_status(6315, '2018-04-04', 'CHP-025269');
select openchpl.add_new_status(6319, '2018-04-04', 'CHP-025271');
select openchpl.add_new_status(6321, '2018-04-04', 'CHP-025272');
select openchpl.add_new_status(6329, '2018-04-04', 'CHP-025276');
select openchpl.add_new_status(6331, '2018-04-04', 'CHP-025277');
select openchpl.add_new_status(6333, '2018-04-04', 'CHP-025278');
select openchpl.add_new_status(6341, '2018-04-04', 'CHP-025282');
select openchpl.add_new_status(6345, '2018-04-04', 'CHP-025284');
select openchpl.add_new_status(6347, '2018-04-04', 'CHP-025285');
select openchpl.add_new_status(6349, '2018-04-04', 'CHP-025286');
select openchpl.add_new_status(6351, '2018-04-04', 'CHP-025287');
select openchpl.add_new_status(6353, '2018-04-04', 'CHP-025288');
select openchpl.add_new_status(6277, '2018-04-04', 'CHP-025289');
select openchpl.add_new_status(6279, '2018-04-04', 'CHP-025290');
select openchpl.add_new_status(6281, '2018-04-04', 'CHP-025291');
select openchpl.add_new_status(6283, '2018-04-04', 'CHP-025292');
select openchpl.add_new_status(6289, '2018-04-04', 'CHP-025295');
select openchpl.add_new_status(6291, '2018-04-04', 'CHP-025296');
select openchpl.add_new_status(6295, '2018-04-04', 'CHP-025298');
select openchpl.add_new_status(6297, '2018-04-04', 'CHP-025299');
select openchpl.add_new_status(6914, '2018-04-04', 'CHP-025370');
select openchpl.add_new_status(6918, '2018-04-04', 'CHP-025345');
select openchpl.add_new_status(6919, '2018-04-04', 'CHP-025346');
select openchpl.add_new_status(6920, '2018-04-04', 'CHP-025347');
select openchpl.add_new_status(6905, '2018-04-04', 'CHP-025348');
select openchpl.add_new_status(6906, '2018-04-04', 'CHP-025349');
select openchpl.add_new_status(6907, '2018-04-04', 'CHP-025350');
select openchpl.add_new_status(6908, '2018-04-04', 'CHP-025351');
select openchpl.add_new_status(6909, '2018-04-04', 'CHP-025352');
select openchpl.add_new_status(6910, '2018-04-04', 'CHP-025353');
select openchpl.add_new_status(6892, '2018-04-04', 'CHP-025354');
select openchpl.add_new_status(6893, '2018-04-04', 'CHP-025355');
select openchpl.add_new_status(6894, '2018-04-04', 'CHP-025356');
select openchpl.add_new_status(6895, '2018-04-04', 'CHP-025357');
select openchpl.add_new_status(6896, '2018-04-04', 'CHP-025358');
select openchpl.add_new_status(6897, '2018-04-04', 'CHP-025359');
select openchpl.add_new_status(6898, '2018-04-04', 'CHP-025360');
select openchpl.add_new_status(6899, '2018-04-04', 'CHP-025361');
select openchpl.add_new_status(6900, '2018-04-04', 'CHP-025362');
select openchpl.add_new_status(6901, '2018-04-04', 'CHP-025363');
select openchpl.add_new_status(6902, '2018-04-04', 'CHP-025364');
select openchpl.add_new_status(6904, '2018-04-04', 'CHP-025366');
select openchpl.add_new_status(6912, '2018-04-04', 'CHP-025368');
select openchpl.add_new_status(6913, '2018-04-04', 'CHP-025369');
select openchpl.add_new_status(6915, '2018-04-04', 'CHP-025371');
select openchpl.add_new_status(6916, '2018-04-04', 'CHP-025372');
select openchpl.add_new_status(6921, '2018-04-04', 'CHP-025373');
select openchpl.add_new_status(7280, '2018-04-04', 'CHP-025385');
select openchpl.add_new_status(7285, '2018-04-04', 'CHP-025386');
select openchpl.add_new_status(7286, '2018-04-04', 'CHP-025387');
select openchpl.add_new_status(7289, '2018-04-04', 'CHP-025390');
select openchpl.add_new_status(7290, '2018-04-04', 'CHP-025391');
select openchpl.add_new_status(7291, '2018-04-04', 'CHP-025392');
select openchpl.add_new_status(7283, '2018-04-04', 'CHP-025394');
select openchpl.add_new_status(7284, '2018-04-04', 'CHP-025395');
select openchpl.add_new_status(7292, '2018-04-04', 'CHP-025396');
select openchpl.add_new_status(5647, '2018-04-04', 'CHP-025445');
select openchpl.add_new_status(7293, '2018-04-04', 'CHP-025397');
select openchpl.add_new_status(7294, '2018-04-04', 'CHP-025398');
select openchpl.add_new_status(7295, '2018-04-04', 'CHP-025399');
select openchpl.add_new_status(7297, '2018-04-04', 'CHP-025400');
select openchpl.add_new_status(7298, '2018-04-04', 'CHP-025401');
select openchpl.add_new_status(7299, '2018-04-04', 'CHP-025402');
select openchpl.add_new_status(7281, '2018-04-04', 'CHP-025403');
select openchpl.add_new_status(5490, '2018-04-04', 'CHP-025467');
select openchpl.add_new_status(5641, '2018-04-04', 'CHP-025421');
select openchpl.add_new_status(5514, '2018-04-04', 'CHP-025422');
select openchpl.add_new_status(5518, '2018-04-04', 'CHP-025423');
select openchpl.add_new_status(5522, '2018-04-04', 'CHP-025424');
select openchpl.add_new_status(5526, '2018-04-04', 'CHP-025425');
select openchpl.add_new_status(5632, '2018-04-04', 'CHP-025426');
select openchpl.add_new_status(5635, '2018-04-04', 'CHP-025427');
select openchpl.add_new_status(5638, '2018-04-04', 'CHP-025428');
select openchpl.add_new_status(5644, '2018-04-04', 'CHP-025429');
select openchpl.add_new_status(5550, '2018-04-04', 'CHP-025440');
select openchpl.add_new_status(5656, '2018-04-04', 'CHP-025444');
select openchpl.add_new_status(5650, '2018-04-04', 'CHP-025446');
select openchpl.add_new_status(5653, '2018-04-04', 'CHP-025447');
select openchpl.add_new_status(5692, '2018-04-04', 'CHP-025448');
select openchpl.add_new_status(5701, '2018-04-04', 'CHP-025451');
select openchpl.add_new_status(5704, '2018-04-04', 'CHP-025452');
select openchpl.add_new_status(5558, '2018-04-04', 'CHP-025453');
select openchpl.add_new_status(5562, '2018-04-04', 'CHP-025454');
select openchpl.add_new_status(5566, '2018-04-04', 'CHP-025455');
select openchpl.add_new_status(5570, '2018-04-04', 'CHP-025456');
select openchpl.add_new_status(5680, '2018-04-04', 'CHP-025460');
select openchpl.add_new_status(5686, '2018-04-04', 'CHP-025462');
select openchpl.add_new_status(5582, '2018-04-04', 'CHP-025463');
select openchpl.add_new_status(5586, '2018-04-04', 'CHP-025464');
select openchpl.add_new_status(5590, '2018-04-04', 'CHP-025465');
select openchpl.add_new_status(5594, '2018-04-04', 'CHP-025466');
select openchpl.add_new_status(5494, '2018-04-04', 'CHP-025468');
select openchpl.add_new_status(5498, '2018-04-04', 'CHP-025469');
select openchpl.add_new_status(5502, '2018-04-04', 'CHP-025470');
select openchpl.add_new_status(5530, '2018-04-04', 'CHP-025471');
select openchpl.add_new_status(5598, '2018-04-04', 'CHP-025472');
select openchpl.add_new_status(5602, '2018-04-04', 'CHP-025473');
select openchpl.add_new_status(5606, '2018-04-04', 'CHP-025474');
select openchpl.add_new_status(5610, '2018-04-04', 'CHP-025475');
select openchpl.add_new_status(5614, '2018-04-04', 'CHP-025476');
select openchpl.add_new_status(5617, '2018-04-04', 'CHP-025477');
select openchpl.add_new_status(5620, '2018-04-04', 'CHP-025478');
select openchpl.add_new_status(5623, '2018-04-04', 'CHP-025479');
select openchpl.add_new_status(5689, '2018-04-04', 'CHP-025480');
select openchpl.add_new_status(5707, '2018-04-04', 'CHP-025481');
select openchpl.add_new_status(5506, '2018-04-04', 'CHP-025482');
select openchpl.add_new_status(6069, '2018-04-04', 'CHP-025541');
select openchpl.add_new_status(5740, '2018-04-04', 'CHP-027073');
select openchpl.add_new_status(5743, '2018-04-04', 'CHP-027074');
select openchpl.add_new_status(5746, '2018-04-04', 'CHP-027075');
select openchpl.add_new_status(5749, '2018-04-04', 'CHP-027076');
select openchpl.add_new_status(5752, '2018-04-04', 'CHP-027077');
select openchpl.add_new_status(5755, '2018-04-04', 'CHP-027078');
select openchpl.add_new_status(5758, '2018-04-04', 'CHP-027079');
select openchpl.add_new_status(5761, '2018-04-04', 'CHP-027080');
select openchpl.add_new_status(5764, '2018-04-04', 'CHP-027081');
select openchpl.add_new_status(5767, '2018-04-04', 'CHP-027082');
select openchpl.add_new_status(5770, '2018-04-04', 'CHP-027083');
select openchpl.add_new_status(5773, '2018-04-04', 'CHP-027084');
select openchpl.add_new_status(5776, '2018-04-04', 'CHP-027085');
select openchpl.add_new_status(5779, '2018-04-04', 'CHP-027086');
select openchpl.add_new_status(5782, '2018-04-04', 'CHP-027087');
select openchpl.add_new_status(5785, '2018-04-04', 'CHP-027088');
select openchpl.add_new_status(5788, '2018-04-04', 'CHP-027089');
select openchpl.add_new_status(5791, '2018-04-04', 'CHP-027090');
select openchpl.add_new_status(5794, '2018-04-04', 'CHP-027091');
select openchpl.add_new_status(5797, '2018-04-04', 'CHP-027092');
select openchpl.add_new_status(5800, '2018-04-04', 'CHP-027093');
select openchpl.add_new_status(5803, '2018-04-04', 'CHP-027094');
select openchpl.add_new_status(5806, '2018-04-04', 'CHP-027095');
select openchpl.add_new_status(5809, '2018-04-04', 'CHP-027096');
select openchpl.add_new_status(5812, '2018-04-04', 'CHP-027097');
select openchpl.add_new_status(5815, '2018-04-04', 'CHP-027098');
select openchpl.add_new_status(5818, '2018-04-04', 'CHP-027099');
select openchpl.add_new_status(5821, '2018-04-04', 'CHP-027100');
select openchpl.add_new_status(5824, '2018-04-04', 'CHP-027101');
select openchpl.add_new_status(5827, '2018-04-04', 'CHP-027102');
select openchpl.add_new_status(5830, '2018-04-04', 'CHP-027103');
select openchpl.add_new_status(5833, '2018-04-04', 'CHP-027104');
select openchpl.add_new_status(5839, '2018-04-04', 'CHP-027106');
select openchpl.add_new_status(5842, '2018-04-04', 'CHP-027107');
select openchpl.add_new_status(5845, '2018-04-04', 'CHP-027108');
select openchpl.add_new_status(5854, '2018-04-04', 'CHP-027111');
select openchpl.add_new_status(5857, '2018-04-04', 'CHP-027112');
select openchpl.add_new_status(5860, '2018-04-04', 'CHP-027113');
select openchpl.add_new_status(5863, '2018-04-04', 'CHP-027114');
select openchpl.add_new_status(5866, '2018-04-04', 'CHP-027115');
select openchpl.add_new_status(5869, '2018-04-04', 'CHP-027116');
select openchpl.add_new_status(5872, '2018-04-04', 'CHP-027117');
select openchpl.add_new_status(5928, '2018-04-04', 'CHP-027125');
select openchpl.add_new_status(7593, '2018-04-04', 'CHP-028516');
select openchpl.add_new_status(6228, '2018-04-04', 'CHP-027267');
select openchpl.add_new_status(6231, '2018-04-04', 'CHP-027268');
select openchpl.add_new_status(6234, '2018-04-04', 'CHP-027269');
select openchpl.add_new_status(6237, '2018-04-04', 'CHP-027270');
select openchpl.add_new_status(5958, '2018-04-04', 'CHP-028963');
select openchpl.add_new_status(7425, '2018-04-04', 'CHP-028682');
select openchpl.add_new_status(7488, '2018-04-04', 'CHP-028305');
select openchpl.add_new_status(7489, '2018-04-04', 'CHP-028306');
select openchpl.add_new_status(7490, '2018-04-04', 'CHP-028307');
select openchpl.add_new_status(7044, '2018-04-04', 'CHP-028024');
select openchpl.add_new_status(6948, '2018-04-04', 'CHP-028048');
select openchpl.add_new_status(6982, '2018-04-04', 'CHP-028082');
select openchpl.add_new_status(7491, '2018-04-04', 'CHP-028308');
select openchpl.add_new_status(6924, '2018-04-04', 'CHP-027920');
select openchpl.add_new_status(6925, '2018-04-04', 'CHP-027921');
select openchpl.add_new_status(6986, '2018-04-04', 'CHP-027935');
select openchpl.add_new_status(6987, '2018-04-04', 'CHP-027936');
select openchpl.add_new_status(6988, '2018-04-04', 'CHP-027937');
select openchpl.add_new_status(6989, '2018-04-04', 'CHP-027938');
select openchpl.add_new_status(6990, '2018-04-04', 'CHP-027939');
select openchpl.add_new_status(6991, '2018-04-04', 'CHP-027940');
select openchpl.add_new_status(6992, '2018-04-04', 'CHP-027941');
select openchpl.add_new_status(6993, '2018-04-04', 'CHP-027942');
select openchpl.add_new_status(6994, '2018-04-04', 'CHP-027943');
select openchpl.add_new_status(6995, '2018-04-04', 'CHP-027944');
select openchpl.add_new_status(6996, '2018-04-04', 'CHP-027945');
select openchpl.add_new_status(6997, '2018-04-04', 'CHP-027946');
select openchpl.add_new_status(6998, '2018-04-04', 'CHP-027947');
select openchpl.add_new_status(6999, '2018-04-04', 'CHP-027948');
select openchpl.add_new_status(7000, '2018-04-04', 'CHP-027949');
select openchpl.add_new_status(7001, '2018-04-04', 'CHP-027950');
select openchpl.add_new_status(7002, '2018-04-04', 'CHP-027951');
select openchpl.add_new_status(7003, '2018-04-04', 'CHP-027952');
select openchpl.add_new_status(7004, '2018-04-04', 'CHP-027953');
select openchpl.add_new_status(7005, '2018-04-04', 'CHP-027954');
select openchpl.add_new_status(7007, '2018-04-04', 'CHP-027956');
select openchpl.add_new_status(7008, '2018-04-04', 'CHP-027957');
select openchpl.add_new_status(7009, '2018-04-04', 'CHP-027958');
select openchpl.add_new_status(7010, '2018-04-04', 'CHP-027959');
select openchpl.add_new_status(7011, '2018-04-04', 'CHP-027960');
select openchpl.add_new_status(7012, '2018-04-04', 'CHP-027961');
select openchpl.add_new_status(7013, '2018-04-04', 'CHP-027962');
select openchpl.add_new_status(7014, '2018-04-04', 'CHP-027963');
select openchpl.add_new_status(7015, '2018-04-04', 'CHP-027964');
select openchpl.add_new_status(7016, '2018-04-04', 'CHP-027965');
select openchpl.add_new_status(7017, '2018-04-04', 'CHP-027966');
select openchpl.add_new_status(7018, '2018-04-04', 'CHP-027967');
select openchpl.add_new_status(7019, '2018-04-04', 'CHP-027968');
select openchpl.add_new_status(7020, '2018-04-04', 'CHP-027969');
select openchpl.add_new_status(7021, '2018-04-04', 'CHP-027970');
select openchpl.add_new_status(7022, '2018-04-04', 'CHP-027971');
select openchpl.add_new_status(7023, '2018-04-04', 'CHP-027972');
select openchpl.add_new_status(7024, '2018-04-04', 'CHP-027973');
select openchpl.add_new_status(7025, '2018-04-04', 'CHP-027974');
select openchpl.add_new_status(7026, '2018-04-04', 'CHP-027975');
select openchpl.add_new_status(7027, '2018-04-04', 'CHP-027976');
select openchpl.add_new_status(7028, '2018-04-04', 'CHP-027977');
select openchpl.add_new_status(7029, '2018-04-04', 'CHP-027978');
select openchpl.add_new_status(7030, '2018-04-04', 'CHP-027979');
select openchpl.add_new_status(7031, '2018-04-04', 'CHP-027980');
select openchpl.add_new_status(7032, '2018-04-04', 'CHP-027981');
select openchpl.add_new_status(7045, '2018-04-04', 'CHP-028025');
select openchpl.add_new_status(7056, '2018-04-04', 'CHP-027996');
select openchpl.add_new_status(7053, '2018-04-04', 'CHP-027994');
select openchpl.add_new_status(7055, '2018-04-04', 'CHP-027995');
select openchpl.add_new_status(7057, '2018-04-04', 'CHP-027997');
select openchpl.add_new_status(7058, '2018-04-04', 'CHP-027998');
select openchpl.add_new_status(7059, '2018-04-04', 'CHP-027999');
select openchpl.add_new_status(7060, '2018-04-04', 'CHP-028000');
select openchpl.add_new_status(7061, '2018-04-04', 'CHP-028001');
select openchpl.add_new_status(7062, '2018-04-04', 'CHP-028002');
select openchpl.add_new_status(7063, '2018-04-04', 'CHP-028003');
select openchpl.add_new_status(7064, '2018-04-04', 'CHP-028004');
select openchpl.add_new_status(7065, '2018-04-04', 'CHP-028005');
select openchpl.add_new_status(7066, '2018-04-04', 'CHP-028006');
select openchpl.add_new_status(7067, '2018-04-04', 'CHP-028007');
select openchpl.add_new_status(7068, '2018-04-04', 'CHP-028008');
select openchpl.add_new_status(7069, '2018-04-04', 'CHP-028009');
select openchpl.add_new_status(7070, '2018-04-04', 'CHP-028010');
select openchpl.add_new_status(7071, '2018-04-04', 'CHP-028011');
select openchpl.add_new_status(7072, '2018-04-04', 'CHP-028012');
select openchpl.add_new_status(7033, '2018-04-04', 'CHP-028013');
select openchpl.add_new_status(7034, '2018-04-04', 'CHP-028014');
select openchpl.add_new_status(7530, '2018-04-04', 'CHP-028353');
select openchpl.add_new_status(7531, '2018-04-04', 'CHP-028354');
select openchpl.add_new_status(7035, '2018-04-04', 'CHP-028015');
select openchpl.add_new_status(7036, '2018-04-04', 'CHP-028016');
select openchpl.add_new_status(7037, '2018-04-04', 'CHP-028017');
select openchpl.add_new_status(7038, '2018-04-04', 'CHP-028018');
select openchpl.add_new_status(7039, '2018-04-04', 'CHP-028019');
select openchpl.add_new_status(7040, '2018-04-04', 'CHP-028020');
select openchpl.add_new_status(7041, '2018-04-04', 'CHP-028021');
select openchpl.add_new_status(7042, '2018-04-04', 'CHP-028022');
select openchpl.add_new_status(7043, '2018-04-04', 'CHP-028023');
select openchpl.add_new_status(7048, '2018-04-04', 'CHP-028028');
select openchpl.add_new_status(7046, '2018-04-04', 'CHP-028026');
select openchpl.add_new_status(7047, '2018-04-04', 'CHP-028027');
select openchpl.add_new_status(7049, '2018-04-04', 'CHP-028029');
select openchpl.add_new_status(7569, '2018-04-04', 'CHP-028482');
select openchpl.add_new_status(7573, '2018-04-04', 'CHP-028486');
select openchpl.add_new_status(7575, '2018-04-04', 'CHP-028488');
select openchpl.add_new_status(7589, '2018-04-04', 'CHP-028490');
select openchpl.add_new_status(7596, '2018-04-04', 'CHP-028494');
select openchpl.add_new_status(6981, '2018-04-04', 'CHP-028081');
select openchpl.add_new_status(7580, '2018-04-04', 'CHP-028500');
select openchpl.add_new_status(7050, '2018-04-04', 'CHP-028030');
select openchpl.add_new_status(7051, '2018-04-04', 'CHP-028031');
select openchpl.add_new_status(7052, '2018-04-04', 'CHP-028032');
select openchpl.add_new_status(7054, '2018-04-04', 'CHP-028033');
select openchpl.add_new_status(6980, '2018-04-04', 'CHP-028080');
select openchpl.add_new_status(6950, '2018-04-04', 'CHP-028050');
select openchpl.add_new_status(6949, '2018-04-04', 'CHP-028049');
select openchpl.add_new_status(6951, '2018-04-04', 'CHP-028051');
select openchpl.add_new_status(6952, '2018-04-04', 'CHP-028052');
select openchpl.add_new_status(6953, '2018-04-04', 'CHP-028053');
select openchpl.add_new_status(6954, '2018-04-04', 'CHP-028054');
select openchpl.add_new_status(6955, '2018-04-04', 'CHP-028055');
select openchpl.add_new_status(6956, '2018-04-04', 'CHP-028056');
select openchpl.add_new_status(6957, '2018-04-04', 'CHP-028057');
select openchpl.add_new_status(6958, '2018-04-04', 'CHP-028058');
select openchpl.add_new_status(6959, '2018-04-04', 'CHP-028059');
select openchpl.add_new_status(6960, '2018-04-04', 'CHP-028060');
select openchpl.add_new_status(6961, '2018-04-04', 'CHP-028061');
select openchpl.add_new_status(6962, '2018-04-04', 'CHP-028062');
select openchpl.add_new_status(6963, '2018-04-04', 'CHP-028063');
select openchpl.add_new_status(6964, '2018-04-04', 'CHP-028064');
select openchpl.add_new_status(6965, '2018-04-04', 'CHP-028065');
select openchpl.add_new_status(6966, '2018-04-04', 'CHP-028066');
select openchpl.add_new_status(6967, '2018-04-04', 'CHP-028067');
select openchpl.add_new_status(6968, '2018-04-04', 'CHP-028068');
select openchpl.add_new_status(6969, '2018-04-04', 'CHP-028069');
select openchpl.add_new_status(6970, '2018-04-04', 'CHP-028070');
select openchpl.add_new_status(6971, '2018-04-04', 'CHP-028071');
select openchpl.add_new_status(6972, '2018-04-04', 'CHP-028072');
select openchpl.add_new_status(6973, '2018-04-04', 'CHP-028073');
select openchpl.add_new_status(6974, '2018-04-04', 'CHP-028074');
select openchpl.add_new_status(6975, '2018-04-04', 'CHP-028075');
select openchpl.add_new_status(6976, '2018-04-04', 'CHP-028076');
select openchpl.add_new_status(6977, '2018-04-04', 'CHP-028077');
select openchpl.add_new_status(6978, '2018-04-04', 'CHP-028078');
select openchpl.add_new_status(6979, '2018-04-04', 'CHP-028079');
select openchpl.add_new_status(6983, '2018-04-04', 'CHP-028083');
select openchpl.add_new_status(6984, '2018-04-04', 'CHP-028084');
select openchpl.add_new_status(6985, '2018-04-04', 'CHP-028085');
select openchpl.add_new_status(6650, '2018-04-04', 'CHP-019917');
select openchpl.add_new_status(6652, '2018-04-04', 'CHP-019918');
select openchpl.add_new_status(7157, '2018-04-04', 'CHP-020897');
select openchpl.add_new_status(7153, '2018-04-04', 'CHP-020899');
select openchpl.add_new_status(7160, '2018-04-04', 'CHP-020903');
select openchpl.add_new_status(7161, '2018-04-04', 'CHP-020904');
select openchpl.add_new_status(7163, '2018-04-04', 'CHP-020906');
select openchpl.add_new_status(7166, '2018-04-04', 'CHP-020909');
select openchpl.add_new_status(6153, '2018-04-04', 'CHP-021128');
select openchpl.add_new_status(6159, '2018-04-04', 'CHP-021130');
select openchpl.add_new_status(6129, '2018-04-04', 'CHP-021145');
select openchpl.add_new_status(5459, '2018-04-04', 'CHP-021405');
select openchpl.add_new_status(5419, '2018-04-04', 'CHP-021407');
select openchpl.add_new_status(5423, '2018-04-04', 'CHP-021408');
select openchpl.add_new_status(5427, '2018-04-04', 'CHP-021409');
select openchpl.add_new_status(5431, '2018-04-04', 'CHP-021410');
select openchpl.add_new_status(5435, '2018-04-04', 'CHP-021411');
select openchpl.add_new_status(5443, '2018-04-04', 'CHP-021413');
select openchpl.add_new_status(5415, '2018-04-04', 'CHP-021414');
select openchpl.add_new_status(6774, '2018-04-04', 'CHP-021532');
select openchpl.add_new_status(6868, '2018-04-04', 'CHP-021634');
select openchpl.add_new_status(6871, '2018-04-04', 'CHP-021637');
select openchpl.add_new_status(6865, '2018-04-04', 'CHP-021660');
select openchpl.add_new_status(6436, '2018-04-04', 'CHP-021665');
select openchpl.add_new_status(6442, '2018-04-04', 'CHP-021668');
select openchpl.add_new_status(6424, '2018-04-04', 'CHP-021670');
select openchpl.add_new_status(6426, '2018-04-04', 'CHP-021671');
select openchpl.add_new_status(6430, '2018-04-04', 'CHP-021673');
select openchpl.add_new_status(6434, '2018-04-04', 'CHP-021675');
select openchpl.add_new_status(6446, '2018-04-04', 'CHP-021676');
select openchpl.add_new_status(5874, '2018-04-04', 'CHP-021713');
select openchpl.add_new_status(7559, '2018-04-04', 'CHP-021738');
select openchpl.add_new_status(5880, '2018-04-04', 'CHP-021715');
select openchpl.add_new_status(5883, '2018-04-04', 'CHP-021716');
select openchpl.add_new_status(5886, '2018-04-04', 'CHP-021717');
select openchpl.add_new_status(5889, '2018-04-04', 'CHP-021718');
select openchpl.add_new_status(5892, '2018-04-04', 'CHP-021719');
select openchpl.add_new_status(5895, '2018-04-04', 'CHP-021720');
select openchpl.add_new_status(7562, '2018-04-04', 'CHP-021741');
select openchpl.add_new_status(7492, '2018-04-04', 'CHP-028309');
select openchpl.add_new_status(7493, '2018-04-04', 'CHP-028310');
select openchpl.add_new_status(7494, '2018-04-04', 'CHP-028311');
select openchpl.add_new_status(7495, '2018-04-04', 'CHP-028312');
select openchpl.add_new_status(7496, '2018-04-04', 'CHP-028313');
select openchpl.add_new_status(7497, '2018-04-04', 'CHP-028314');
select openchpl.add_new_status(7498, '2018-04-04', 'CHP-028315');
select openchpl.add_new_status(7499, '2018-04-04', 'CHP-028316');
select openchpl.add_new_status(7500, '2018-04-04', 'CHP-028317');
select openchpl.add_new_status(7501, '2018-04-04', 'CHP-028318');
select openchpl.add_new_status(7502, '2018-04-04', 'CHP-028319');
select openchpl.add_new_status(7503, '2018-04-04', 'CHP-028320');
select openchpl.add_new_status(7504, '2018-04-04', 'CHP-028321');
select openchpl.add_new_status(7505, '2018-04-04', 'CHP-028322');
select openchpl.add_new_status(7506, '2018-04-04', 'CHP-028323');
select openchpl.add_new_status(7507, '2018-04-04', 'CHP-028324');
select openchpl.add_new_status(7508, '2018-04-04', 'CHP-028325');
select openchpl.add_new_status(7509, '2018-04-04', 'CHP-028326');
select openchpl.add_new_status(7510, '2018-04-04', 'CHP-028327');
select openchpl.add_new_status(7511, '2018-04-04', 'CHP-028328');
select openchpl.add_new_status(7512, '2018-04-04', 'CHP-028335');
select openchpl.add_new_status(7514, '2018-04-04', 'CHP-028337');
select openchpl.add_new_status(7515, '2018-04-04', 'CHP-028338');
select openchpl.add_new_status(7516, '2018-04-04', 'CHP-028339');
select openchpl.add_new_status(7517, '2018-04-04', 'CHP-028340');
select openchpl.add_new_status(7518, '2018-04-04', 'CHP-028341');
select openchpl.add_new_status(7519, '2018-04-04', 'CHP-028342');
select openchpl.add_new_status(7520, '2018-04-04', 'CHP-028343');
select openchpl.add_new_status(7521, '2018-04-04', 'CHP-028344');
select openchpl.add_new_status(7522, '2018-04-04', 'CHP-028345');
select openchpl.add_new_status(7523, '2018-04-04', 'CHP-028346');
select openchpl.add_new_status(7524, '2018-04-04', 'CHP-028347');
select openchpl.add_new_status(7525, '2018-04-04', 'CHP-028348');
select openchpl.add_new_status(7526, '2018-04-04', 'CHP-028349');
select openchpl.add_new_status(7527, '2018-04-04', 'CHP-028350');
select openchpl.add_new_status(7528, '2018-04-04', 'CHP-028351');
select openchpl.add_new_status(7529, '2018-04-04', 'CHP-028352');
select openchpl.add_new_status(7539, '2018-04-04', 'CHP-028429');
select openchpl.add_new_status(7581, '2018-04-04', 'CHP-028501');
select openchpl.add_new_status(7542, '2018-04-04', 'CHP-028431');
select openchpl.add_new_status(7544, '2018-04-04', 'CHP-028433');
select openchpl.add_new_status(7546, '2018-04-04', 'CHP-028435');
select openchpl.add_new_status(6006, '2018-04-04', 'CHP-028457');
select openchpl.add_new_status(7211, '2018-04-04', 'CHP-028570');
select openchpl.add_new_status(6009, '2018-04-04', 'CHP-028458');
select openchpl.add_new_status(6000, '2018-04-04', 'CHP-028459');
select openchpl.add_new_status(6003, '2018-04-04', 'CHP-028460');
select openchpl.add_new_status(6012, '2018-04-04', 'CHP-028461');
select openchpl.add_new_status(6015, '2018-04-04', 'CHP-028462');
select openchpl.add_new_status(6018, '2018-04-04', 'CHP-028463');
select openchpl.add_new_status(5991, '2018-04-04', 'CHP-028464');
select openchpl.add_new_status(5994, '2018-04-04', 'CHP-028465');
select openchpl.add_new_status(5997, '2018-04-04', 'CHP-028466');
select openchpl.add_new_status(5970, '2018-04-04', 'CHP-028467');
select openchpl.add_new_status(5973, '2018-04-04', 'CHP-028468');
select openchpl.add_new_status(5976, '2018-04-04', 'CHP-028469');
select openchpl.add_new_status(5979, '2018-04-04', 'CHP-028470');
select openchpl.add_new_status(5982, '2018-04-04', 'CHP-028471');
select openchpl.add_new_status(5985, '2018-04-04', 'CHP-028472');
select openchpl.add_new_status(5988, '2018-04-04', 'CHP-028473');
select openchpl.add_new_status(6024, '2018-04-04', 'CHP-028474');
select openchpl.add_new_status(6021, '2018-04-04', 'CHP-028475');
select openchpl.add_new_status(7572, '2018-04-04', 'CHP-028485');
select openchpl.add_new_status(7577, '2018-04-04', 'CHP-028497');
select openchpl.add_new_status(7578, '2018-04-04', 'CHP-028498');
select openchpl.add_new_status(7603, '2018-04-04', 'CHP-028506');
select openchpl.add_new_status(7604, '2018-04-04', 'CHP-028507');
select openchpl.add_new_status(7582, '2018-04-04', 'CHP-028508');
select openchpl.add_new_status(7583, '2018-04-04', 'CHP-028509');
select openchpl.add_new_status(7584, '2018-04-04', 'CHP-028510');
select openchpl.add_new_status(7585, '2018-04-04', 'CHP-028511');
select openchpl.add_new_status(7586, '2018-04-04', 'CHP-028512');
select openchpl.add_new_status(7587, '2018-04-04', 'CHP-028513');
select openchpl.add_new_status(7588, '2018-04-04', 'CHP-028514');
select openchpl.add_new_status(7592, '2018-04-04', 'CHP-028515');
select openchpl.add_new_status(7201, '2018-04-04', 'CHP-028532');
select openchpl.add_new_status(7202, '2018-04-04', 'CHP-028533');
select openchpl.add_new_status(7203, '2018-04-04', 'CHP-028534');
select openchpl.add_new_status(7204, '2018-04-04', 'CHP-028535');
select openchpl.add_new_status(7205, '2018-04-04', 'CHP-028536');
select openchpl.add_new_status(7214, '2018-04-04', 'CHP-028537');
select openchpl.add_new_status(7215, '2018-04-04', 'CHP-028538');
select openchpl.add_new_status(7216, '2018-04-04', 'CHP-028540');
select openchpl.add_new_status(7218, '2018-04-04', 'CHP-028542');
select openchpl.add_new_status(7219, '2018-04-04', 'CHP-028543');
select openchpl.add_new_status(7223, '2018-04-04', 'CHP-028547');
select openchpl.add_new_status(7224, '2018-04-04', 'CHP-028548');
select openchpl.add_new_status(7227, '2018-04-04', 'CHP-028551');
select openchpl.add_new_status(7235, '2018-04-04', 'CHP-028552');
select openchpl.add_new_status(7236, '2018-04-04', 'CHP-028553');
select openchpl.add_new_status(7237, '2018-04-04', 'CHP-028554');
select openchpl.add_new_status(7238, '2018-04-04', 'CHP-028555');
select openchpl.add_new_status(7183, '2018-04-04', 'CHP-028556');
select openchpl.add_new_status(7186, '2018-04-04', 'CHP-028557');
select openchpl.add_new_status(7187, '2018-04-04', 'CHP-028558');
select openchpl.add_new_status(7231, '2018-04-04', 'CHP-028564');
select openchpl.add_new_status(7209, '2018-04-04', 'CHP-028568');
select openchpl.add_new_status(7180, '2018-04-04', 'CHP-028572');
select openchpl.add_new_status(7233, '2018-04-04', 'CHP-028573');
select openchpl.add_new_status(7230, '2018-04-04', 'CHP-028575');
select openchpl.add_new_status(7177, '2018-04-04', 'CHP-028580');
select openchpl.add_new_status(7178, '2018-04-04', 'CHP-028581');
select openchpl.add_new_status(7179, '2018-04-04', 'CHP-028582');
select openchpl.add_new_status(7212, '2018-04-04', 'CHP-028583');
select openchpl.add_new_status(7213, '2018-04-04', 'CHP-028584');
select openchpl.add_new_status(7181, '2018-04-04', 'CHP-028585');
select openchpl.add_new_status(7182, '2018-04-04', 'CHP-028586');
select openchpl.add_new_status(7194, '2018-04-04', 'CHP-028587');
select openchpl.add_new_status(7195, '2018-04-04', 'CHP-028588');
select openchpl.add_new_status(7196, '2018-04-04', 'CHP-028589');
select openchpl.add_new_status(7197, '2018-04-04', 'CHP-028590');
select openchpl.add_new_status(7198, '2018-04-04', 'CHP-028591');
select openchpl.add_new_status(7184, '2018-04-04', 'CHP-028592');
select openchpl.add_new_status(7185, '2018-04-04', 'CHP-028593');
select openchpl.add_new_status(7437, '2018-04-04', 'CHP-028694');
select openchpl.add_new_status(7429, '2018-04-04', 'CHP-028686');
select openchpl.add_new_status(7430, '2018-04-04', 'CHP-028687');
select openchpl.add_new_status(7431, '2018-04-04', 'CHP-028688');
select openchpl.add_new_status(7432, '2018-04-04', 'CHP-028689');
select openchpl.add_new_status(7433, '2018-04-04', 'CHP-028690');
select openchpl.add_new_status(7434, '2018-04-04', 'CHP-028691');
select openchpl.add_new_status(7435, '2018-04-04', 'CHP-028692');
select openchpl.add_new_status(7436, '2018-04-04', 'CHP-028693');
select openchpl.add_new_status(7438, '2018-04-04', 'CHP-028695');
select openchpl.add_new_status(7439, '2018-04-04', 'CHP-028696');
select openchpl.add_new_status(7440, '2018-04-04', 'CHP-028697');
select openchpl.add_new_status(7441, '2018-04-04', 'CHP-028698');
select openchpl.add_new_status(7393, '2018-04-04', 'CHP-028699');
select openchpl.add_new_status(7394, '2018-04-04', 'CHP-028700');
select openchpl.add_new_status(7395, '2018-04-04', 'CHP-028701');
select openchpl.add_new_status(7396, '2018-04-04', 'CHP-028702');
select openchpl.add_new_status(7397, '2018-04-04', 'CHP-028703');
select openchpl.add_new_status(7111, '2018-04-04', 'CHP-028712');
select openchpl.add_new_status(7114, '2018-04-04', 'CHP-028715');
select openchpl.add_new_status(6036, '2018-04-04', 'CHP-028977');
select openchpl.add_new_status(6039, '2018-04-04', 'CHP-028978');
select openchpl.add_new_status(7464, '2018-04-04', 'CHP-028981');
select openchpl.add_new_status(7465, '2018-04-04', 'CHP-028982');
select openchpl.add_new_status(7466, '2018-04-04', 'CHP-028983');
select openchpl.add_new_status(7467, '2018-04-04', 'CHP-028984');
select openchpl.add_new_status(7442, '2018-04-04', 'CHP-028985');
select openchpl.add_new_status(7443, '2018-04-04', 'CHP-028986');
select openchpl.add_new_status(7448, '2018-04-04', 'CHP-028991');
select openchpl.add_new_status(7449, '2018-04-04', 'CHP-028992');
select openchpl.add_new_status(7450, '2018-04-04', 'CHP-028993');
select openchpl.add_new_status(7451, '2018-04-04', 'CHP-028994');
select openchpl.add_new_status(7452, '2018-04-04', 'CHP-028995');
select openchpl.add_new_status(7453, '2018-04-04', 'CHP-028996');
select openchpl.add_new_status(7455, '2018-04-04', 'CHP-028998');
select openchpl.add_new_status(7456, '2018-04-04', 'CHP-028999');
select openchpl.add_new_status(7457, '2018-04-04', 'CHP-029000');
select openchpl.add_new_status(6455, '2018-04-04', 'CHP-029137');
select openchpl.add_new_status(6419, '2018-04-04', 'CHP-029139');
select openchpl.add_new_status(6421, '2018-04-04', 'CHP-029140');
select openchpl.add_new_status(6427, '2018-04-04', 'CHP-029144');
select openchpl.add_new_status(6445, '2018-04-04', 'CHP-029150');
select openchpl.add_new_status(6457, '2018-04-04', 'CHP-029153');
select openchpl.add_new_status(6459, '2018-04-04', 'CHP-029154');
select openchpl.add_new_status(6373, '2018-04-04', 'CHP-029187');
select openchpl.add_new_status(6375, '2018-04-04', 'CHP-029188');
select openchpl.add_new_status(6371, '2018-04-04', 'CHP-029189');
select openchpl.add_new_status(6409, '2018-04-04', 'CHP-029190');
select openchpl.add_new_status(6411, '2018-04-04', 'CHP-029191');
select openchpl.add_new_status(6403, '2018-04-04', 'CHP-029192');
select openchpl.add_new_status(6413, '2018-04-04', 'CHP-029193');
select openchpl.add_new_status(6415, '2018-04-04', 'CHP-029194');
select openchpl.add_new_status(6377, '2018-04-04', 'CHP-029195');
select openchpl.add_new_status(6383, '2018-04-04', 'CHP-029196');
select openchpl.add_new_status(6385, '2018-04-04', 'CHP-029197');
select openchpl.add_new_status(6379, '2018-04-04', 'CHP-029198');
select openchpl.add_new_status(6381, '2018-04-04', 'CHP-029199');
select openchpl.add_new_status(6405, '2018-04-04', 'CHP-029200');
select openchpl.add_new_status(6407, '2018-04-04', 'CHP-029201');
select openchpl.add_new_status(6387, '2018-04-04', 'CHP-029202');
select openchpl.add_new_status(6389, '2018-04-04', 'CHP-029203');
select openchpl.add_new_status(6391, '2018-04-04', 'CHP-029204');
select openchpl.add_new_status(6393, '2018-04-04', 'CHP-029205');
select openchpl.add_new_status(5751, '2018-04-04', 'CHP-029212');
select openchpl.add_new_status(5757, '2018-04-04', 'CHP-029214');
select openchpl.add_new_status(5778, '2018-04-04', 'CHP-029221');
select openchpl.add_new_status(5784, '2018-04-04', 'CHP-029223');
select openchpl.add_new_status(5787, '2018-04-04', 'CHP-029224');
select openchpl.add_new_status(5793, '2018-04-04', 'CHP-029226');

drop function openchpl.add_new_status(bigint, timestamp, varchar(64));
drop function openchpl.can_add_new_status(bigint, timestamp, varchar(64));
