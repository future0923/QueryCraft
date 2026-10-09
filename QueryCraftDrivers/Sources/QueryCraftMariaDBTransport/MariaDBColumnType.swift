import CMariaDB

package enum MariaDBColumnType {
    package static func name(for field: MYSQL_FIELD) -> String? {
        let name: String
        switch field.type {
        case MYSQL_TYPE_TINY: name = "tinyint"
        case MYSQL_TYPE_SHORT: name = "smallint"
        case MYSQL_TYPE_LONG: name = "int"
        case MYSQL_TYPE_INT24: name = "mediumint"
        case MYSQL_TYPE_LONGLONG: name = "bigint"
        case MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL: name = "decimal"
        case MYSQL_TYPE_FLOAT: name = "float"
        case MYSQL_TYPE_DOUBLE: name = "double"
        case MYSQL_TYPE_NULL: name = "null"
        case MYSQL_TYPE_TIMESTAMP, MYSQL_TYPE_TIMESTAMP2: name = "timestamp"
        case MYSQL_TYPE_DATE, MYSQL_TYPE_NEWDATE: name = "date"
        case MYSQL_TYPE_TIME, MYSQL_TYPE_TIME2: name = "time"
        case MYSQL_TYPE_DATETIME, MYSQL_TYPE_DATETIME2: name = "datetime"
        case MYSQL_TYPE_YEAR: name = "year"
        case MYSQL_TYPE_BIT: name = "bit"
        case MYSQL_TYPE_JSON: name = "json"
        case MYSQL_TYPE_ENUM: name = "enum"
        case MYSQL_TYPE_SET: name = "set"
        case MYSQL_TYPE_VARCHAR, MYSQL_TYPE_VAR_STRING:
            name = field.charsetnr == 63 ? "varbinary" : "varchar"
        case MYSQL_TYPE_STRING:
            name = field.charsetnr == 63 ? "binary" : "char"
        case MYSQL_TYPE_TINY_BLOB: name = field.charsetnr == 63 ? "tinyblob" : "tinytext"
        case MYSQL_TYPE_MEDIUM_BLOB: name = field.charsetnr == 63 ? "mediumblob" : "mediumtext"
        case MYSQL_TYPE_LONG_BLOB: name = field.charsetnr == 63 ? "longblob" : "longtext"
        case MYSQL_TYPE_BLOB: name = field.charsetnr == 63 ? "blob" : "text"
        case MYSQL_TYPE_GEOMETRY: name = "geometry"
        default: return nil
        }
        let numericTypes = [MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_LONG,
                            MYSQL_TYPE_INT24, MYSQL_TYPE_LONGLONG, MYSQL_TYPE_DECIMAL,
                            MYSQL_TYPE_NEWDECIMAL, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE]
        return numericTypes.contains(field.type) && field.flags & UInt32(UNSIGNED_FLAG) != 0
            ? name + " unsigned" : name
    }
}
