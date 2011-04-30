--
-- PostgreSQL database dump
--

SET client_encoding = 'UTF8';
SET standard_conforming_strings = off;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET escape_string_warning = off;

SET search_path = public, pg_catalog;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: predictive_dialing; Type: TABLE; Schema: public; Owner: asterisk; Tablespace: 
--

CREATE TABLE predictive_dialing (
    id bigint NOT NULL,
    destination character(15) NOT NULL,
    create_date timestamp without time zone DEFAULT now(),
    done_date timestamp without time zone,
    linked_with character(15),
    tries smallint DEFAULT 0,
    billsec integer DEFAULT 0,
    userfield character(256),
    uuid uuid,
    when_last_try timestamp without time zone,
    since timestamp without time zone DEFAULT now(),
    till timestamp without time zone DEFAULT (now() + '1 day'::interval)
);


ALTER TABLE public.predictive_dialing OWNER TO asterisk;

--
-- Name: predictive_dialing_id_seq; Type: SEQUENCE; Schema: public; Owner: asterisk
--

CREATE SEQUENCE predictive_dialing_id_seq
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;


ALTER TABLE public.predictive_dialing_id_seq OWNER TO asterisk;

--
-- Name: predictive_dialing_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: asterisk
--

ALTER SEQUENCE predictive_dialing_id_seq OWNED BY predictive_dialing.id;


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: asterisk
--

ALTER TABLE predictive_dialing ALTER COLUMN id SET DEFAULT nextval('predictive_dialing_id_seq'::regclass);


--
-- Name: predictive_dialing_pkey; Type: CONSTRAINT; Schema: public; Owner: asterisk; Tablespace: 
--

ALTER TABLE ONLY predictive_dialing
    ADD CONSTRAINT predictive_dialing_pkey PRIMARY KEY (id);


--
-- PostgreSQL database dump complete
--

