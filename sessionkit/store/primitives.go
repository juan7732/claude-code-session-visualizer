package store

import (
	"database/sql"
	"time"
)

// UseRow is one primitive's use on one day of a session (see
// transcript.PrimitiveUse, which it mirrors).
type UseRow struct {
	Kind    string
	Name    string
	Day     string
	Calls   int
	Errors  int
	ByUser  int
	Seconds float64
	Tokens  int
	FirstAt time.Time
	LastAt  time.Time
	Turn    int
	Path    string
}

// OfferRow is a primitive a session had on offer.
type OfferRow struct {
	Kind    string
	Name    string
	BuiltIn bool
}

// ReplacePrimitives swaps what a session used and was offered.
func (s *Store) ReplacePrimitives(session string, uses []UseRow, offered []OfferRow) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM uses WHERE session = ?`, session); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM offered WHERE session = ?`, session); err != nil {
		return err
	}
	use, err := tx.Prepare(`INSERT INTO uses(session, kind, name, day, calls, errors, by_user, seconds, tokens, first_at, last_at, turn, path)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer use.Close()
	for _, u := range uses {
		if _, err := use.Exec(session, u.Kind, u.Name, u.Day, u.Calls, u.Errors, u.ByUser, u.Seconds, u.Tokens,
			timeText(u.FirstAt), timeText(u.LastAt), u.Turn, u.Path); err != nil {
			return err
		}
	}
	offer, err := tx.Prepare(`INSERT INTO offered(session, kind, name, builtin) VALUES(?,?,?,?)`)
	if err != nil {
		return err
	}
	defer offer.Close()
	for _, o := range offered {
		if _, err := offer.Exec(session, o.Kind, o.Name, boolInt(o.BuiltIn)); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SessionUse is a use row with the session it belongs to.
type SessionUse struct {
	Session string
	Title   string
	Project string // the slug Claude Code files the session under
	Cwd     string // the directory the session started in
	UseRow
}

// Uses lists every use, oldest first. kind and name narrow it when not empty.
func (s *Store) Uses(kind, name string) ([]SessionUse, error) {
	q := `SELECT u.session, s.title, s.project, coalesce(json_extract(s.summary, '$.cwd'), ''), u.kind, u.name, u.day, u.calls, u.errors,
		u.by_user, u.seconds, u.tokens, u.first_at, u.last_at, u.turn, u.path
		FROM uses u JOIN sessions s ON s.id = u.session`
	var args []any
	if kind != "" {
		q += ` WHERE u.kind = ?`
		args = append(args, kind)
		if name != "" {
			q += ` AND u.name = ?`
			args = append(args, name)
		}
	}
	rows, err := s.db.Query(q+` ORDER BY u.first_at, u.session, u.kind, u.name`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SessionUse{}
	for rows.Next() {
		var u SessionUse
		var first, last sql.NullString
		if err := rows.Scan(&u.Session, &u.Title, &u.Project, &u.Cwd, &u.Kind, &u.Name, &u.Day, &u.Calls, &u.Errors, &u.ByUser,
			&u.Seconds, &u.Tokens, &first, &last, &u.Turn, &u.Path); err != nil {
			return nil, err
		}
		u.FirstAt, u.LastAt = parseTime(first), parseTime(last)
		out = append(out, u)
	}
	return out, rows.Err()
}

// OfferCount is how many sessions had a primitive on offer.
type OfferCount struct {
	Kind     string
	Name     string
	Sessions int
	BuiltIn  bool
	// LastAt is the latest activity of a session that had it on offer.
	LastAt time.Time
}

// Offers adds up what sessions had on offer. With since, only sessions active
// at or after it count.
func (s *Store) Offers(since time.Time) ([]OfferCount, error) {
	q := `SELECT o.kind, o.name, count(*), max(o.builtin), max(s.last_at) FROM offered o JOIN sessions s ON s.id = o.session`
	var args []any
	if !since.IsZero() {
		q += ` WHERE s.last_at >= ?`
		args = append(args, timeText(since))
	}
	rows, err := s.db.Query(q+` GROUP BY o.kind, o.name ORDER BY o.kind, o.name`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []OfferCount{}
	for rows.Next() {
		var o OfferCount
		var builtin int
		var last sql.NullString
		if err := rows.Scan(&o.Kind, &o.Name, &o.Sessions, &builtin, &last); err != nil {
			return nil, err
		}
		o.BuiltIn, o.LastAt = builtin != 0, parseTime(last)
		out = append(out, o)
	}
	return out, rows.Err()
}

// StartDirs lists the directories sessions started in, as the summaries
// recorded them: the projects the index knows.
func (s *Store) StartDirs() ([]string, error) {
	rows, err := s.db.Query(`SELECT DISTINCT json_extract(summary, '$.cwd') FROM sessions
		WHERE coalesce(json_extract(summary, '$.cwd'), '') <> '' ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// SessionsSince counts the sessions active at or after since (all of them
// when since is zero).
func (s *Store) SessionsSince(since time.Time) (int, error) {
	var n int
	if since.IsZero() {
		return n, s.db.QueryRow(`SELECT count(*) FROM sessions`).Scan(&n)
	}
	return n, s.db.QueryRow(`SELECT count(*) FROM sessions WHERE last_at >= ?`, timeText(since)).Scan(&n)
}
