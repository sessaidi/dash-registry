import Foundation

/// Test-only PKI generated once with openssl (10-year validity): a cluster CA, an unrelated CA,
/// a server certificate for kube.test / 127.0.0.1 (800 days: Apple caps TLS server
/// certificates at 825, so tests evaluate at `Fixtures.verifyDate`), and RSA / EC client certificates signed by the CA.
enum Fixtures {
    static let caCrt = """
        -----BEGIN CERTIFICATE-----
        MIIC8zCCAdugAwIBAgIJAJGB1Q+oR6pbMA0GCSqGSIb3DQEBCwUAMBcxFTATBgNV
        BAMMDGt1YmUtdGVzdC1jYTAeFw0yNjExMTMxNzQ5MzRaFw0zNjExMTAxNzQ5MzRa
        MBcxFTATBgNVBAMMDGt1YmUtdGVzdC1jYTCCASIwDQYJKoZIhvcNAQEBBQADggEP
        ADCCAQoCggEBAMXxFoojsQr+HJL32+Cxq4PRKwhubXY3VZJMh8kNMiq5UuUQeT/d
        w/75td/yMceR8RYWmkkZb0nXPRZnHiOV3F2dbwYaFP5NJ8j1lJXIQtwiaF3rZODg
        va8eIVmJkhKboXj78m5PX7/9RW81yBYrjrdnS3nwku/iDfNXDk9AH9bQe18Cp29h
        BxvB9hbV4TDE010skg82+wd7mWY2w3lNbMdwmA1eIsUPRB1OEomIj+iD9UVY8M10
        1luBAWrtEJVsRJI37jWnZBo49FTddPWvw5HkT6ugnURBICoHDozIxbJe8xYZUpbp
        ayPjuoadfXQ7B4QhJ5yt+JO7MwAES8GHH6MCAwEAAaNCMEAwDwYDVR0TAQH/BAUw
        AwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFNl18RiPpm3XvP4+xghtKSKv
        /z5mMA0GCSqGSIb3DQEBCwUAA4IBAQBDrLLXjB/0Jzasho+wN77WAzxwsPpxDuMG
        3Jhy53/tUn/IFz2BVOAOdzpNbwkbYDbOMLw82lTLWEHq3k8fueoHNP1wQWcExN86
        XwGSVHTRP4zaoQqaUf/VRIA5ncXFmiODxI5iD9UUO/FjYUi0jBHo4W2U5fGVZHI8
        kOT9FJ9wejv0eMLov30fYTXMikfNmsHyD+Q+8QKvVi02J3CoV/9mH0ffvN+vCbFo
        b2yfdi2CKTbnAJlXFQualvywhlFxwXkE4mPIhelFjtxECTRL1aJkcCkqI+C6HpFJ
        TxhabpMpEIfW8sRbv8utt60adw1OY1tAdLKk9wNxuq7p5f0bCxDE
        -----END CERTIFICATE-----
        """
    static let otherCrt = """
        -----BEGIN CERTIFICATE-----
        MIICzDCCAbSgAwIBAgIJALu8df0UhJG2MA0GCSqGSIb3DQEBCwUAMBMxETAPBgNV
        BAMMCG90aGVyLWNhMB4XDTI2MTExMzE3NDkzNFoXDTM2MTExMDE3NDkzNFowEzER
        MA8GA1UEAwwIb3RoZXItY2EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
        AQDtRIhHhZEAf9YsTr/O15GVBnlQkiqODty0jaApogf21nb68VzcQFqZ0+hWZbsY
        hIdJQ3Wp2e9jm5ClC9xOLcwD5IS1STHWfU+mk9YQre+fSJuGOFOuTwSXsrz7pYC0
        r7qI0ldthndnjkgYJUbkItnEoIUeTLjhPdS1dTD0zld5vQDQ6bJT5j6jSuDlVvJq
        HzdEdiKeGLbdmkgPIFf+ug5CUgT340vcCSpD4+npKvT1jmVpWo+B0qE5tzvJ2KUN
        CL9y+1kzYw7pdEqm4mVKOpw9v/zifMR2eDSI6yQ4eRigKqrzZqUaV03k8xL+CfVu
        HKeXoaz66LlJsPOHIe2yQiWDAgMBAAGjIzAhMA8GA1UdEwEB/wQFMAMBAf8wDgYD
        VR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQCWLo/OkbM8MNOwLLIta6Hp
        kFLSQ6vzgldCAaHUqv7ke2UPmoYV0hrVVPf9NjL4EbvhY0Pdw8cVIkpIjDw4F8Ha
        5wNaHzaE4r6/UhOvhB9mFCU7VLu0+BaUQ7hGazPUYME7QMGm2/yPf4xBM0CUgEV5
        RUcaizc6mhYJqKhLMRzGc1zFPrANFcwzfJoHu8wOI/Te6hX03y7CyytrKh54IEUV
        f1WXYl96sJ+QOZVbRR/wQ5v6CczE9OVIzFsbppkgLwV2HId/S2PYq/OnPw/R+NPs
        CN5ibzsRcj/d3rSh+NYMPNgXBBBRJy0QqmYOE5OcRwNkZZraB3DyuzL4kYVbrQnU
        -----END CERTIFICATE-----
        """
    static let serverCrt = """
        -----BEGIN CERTIFICATE-----
        MIIDATCCAemgAwIBAgIJAJBdtSbl+yNjMA0GCSqGSIb3DQEBCwUAMBcxFTATBgNV
        BAMMDGt1YmUtdGVzdC1jYTAeFw0yNjExMTMxNzU4MzdaFw0yOTAxMjExNzU4Mzda
        MBkxFzAVBgNVBAMMDmt1YmUtYXBpc2VydmVyMIIBIjANBgkqhkiG9w0BAQEFAAOC
        AQ8AMIIBCgKCAQEAxtvqcAaQZwUbSzRvEm/zLX5ieei7RFWVWxTFhAG82vLM59YD
        DgYn19D7bFFznEOrDpa0FEDvMBfKzmtSnOvcX++zOtQdU1ph3CVwls5sSc/p2gDL
        tWquP5Mh9PkcnWe3Ke6HSpVRrccyBz7OsbAUinDwc/W2/WxiAmDHz22DWbuy/sNR
        Bz3P1GZPtPSIhpASC1pTVSCYS1r+pEEnpS7KfKvqR6FZMTWzZWoEQc/hxlsb5dbN
        sfmwihTKpccOTZCQf7HW9j7kIQclfS2iQgZyMNk3xSaFuSxI/Kbm33eruGc/e9+p
        vARsBA8jO33OGdh2ClbVgKhNp0jQXbvOlYiYJwIDAQABo04wTDAJBgNVHRMEAjAA
        MA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAaBgNVHREEEzAR
        gglrdWJlLnRlc3SHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBAHr0d0lV6KvSm/4X
        3hClwqk8BD6/be+aYMakCN50idAng61k7SgdKNl81iaEKBlmZFf3+0dHaI82dPyQ
        z8GadJp3qjCpPmxRzb2VSbbnGg9RwNWRZHt3ltJDPIM7RLXZdeU7QxwebiBiFNNm
        DNxJfgT8p6sO2eW4f4stlTSArwKDcw7Pe27900mT9f+EFaPXOeyzf/PDjJyjWVWn
        EwmhQca5jKVlpoGMCoVYFUllCMT2+wEpuo5hpPjhjDzFzuYEbKOxkNZ9PGmwNodE
        /+s/FWRR94HMIQI/BnrsIJKAd7TUC7pHt0KzJuh0cm8I4z7Q2EODsHAC5P0AhJaJ
        4GIvtLI=
        -----END CERTIFICATE-----
        """
    static let clientRsaCrt = """
        -----BEGIN CERTIFICATE-----
        MIIC+jCCAeKgAwIBAgIJAJBdtSbl+yNhMA0GCSqGSIb3DQEBCwUAMBcxFTATBgNV
        BAMMDGt1YmUtdGVzdC1jYTAeFw0yNjExMTMxNzQ5MzVaFw0zNjExMTAxNzQ5MzVa
        MC4xEzARBgNVBAMMCmtpbmQtYWRtaW4xFzAVBgNVBAoMDnN5c3RlbTptYXN0ZXJz
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6j9Jf58XYpT/NCr/+CAD
        vT+CX62yQxh6ULeEIaM5RzHhqZZxV+ORFH8DXSuiXPzASmok1CCG5qUzLg4pUG5w
        Mv4QyC64b1tJZ4H9gVDdLl2W3RLuKNgkVD64PARvjA2KnN547SLgiBxbLxu2OJFt
        QPVt5Ac7QG5fKSQoY2DxyF2HhC3tOD/qN464/nmia9X6k5/RnGnacFwqnYrU0HgP
        2NaIRyHaObAMQA2fkrmvTbJnYYDSgTwi06yxzwrjnHum5U98fBHxSGX8LSdygoXu
        Wz1y0Z0Z5x1j5FVAWQoEOGPI36LE7XuBqKTfEprKNC0oZAd2wNYGgAsM4CeveiEH
        MQIDAQABozIwMDAJBgNVHRMEAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAK
        BggrBgEFBQcDAjANBgkqhkiG9w0BAQsFAAOCAQEAALhS4o4jp7TWkucBMo8GutY7
        sax7c2omsfnenfBkjQCjUFteEd2yRIqv+BenbUMIVm9NFg7mUK3Ov0uOA7uhSzl6
        8Q88SorOtzbN18WaCArIQss1vfMgmz+FuZ0rQzv62LWOQc7530siSGvC/Ee6XNH3
        V7QdceB3eGCc1sBBe4IJBbOVN2fY3pXoHqDUnydxXM18DS/1NjHAQzhgYHCuOg6a
        u+Fkrck0dlTaM7YUjZ0QRiL2U2EOF6Z+VX6r7d0fT4H0oc0AV44acDJpsIk3ak2u
        E7KDlgPGo/ChB4/hXSiiWG+qY6b8fCmY0PtTPXYDZSV9Hc0q0ylUOQtRwggI4w==
        -----END CERTIFICATE-----
        """
    static let clientRsaKey = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA6j9Jf58XYpT/NCr/+CADvT+CX62yQxh6ULeEIaM5RzHhqZZx
        V+ORFH8DXSuiXPzASmok1CCG5qUzLg4pUG5wMv4QyC64b1tJZ4H9gVDdLl2W3RLu
        KNgkVD64PARvjA2KnN547SLgiBxbLxu2OJFtQPVt5Ac7QG5fKSQoY2DxyF2HhC3t
        OD/qN464/nmia9X6k5/RnGnacFwqnYrU0HgP2NaIRyHaObAMQA2fkrmvTbJnYYDS
        gTwi06yxzwrjnHum5U98fBHxSGX8LSdygoXuWz1y0Z0Z5x1j5FVAWQoEOGPI36LE
        7XuBqKTfEprKNC0oZAd2wNYGgAsM4CeveiEHMQIDAQABAoIBAFJHoJ1/WEt8YpgE
        cpzJQgb7g+Pvsyn2MyCfFX5rQvdLAiT7fxyMBq3YX2oepY1cCn8ZAY6xTjE93dhT
        iReDc022CFcIcihLPGFrO4xsxwQ+Q3ur5pPaOAiPb09Fj5j2OLYZPwiss4mbzDuj
        1EHScznZ+5uZHqrnGe3tkXI23zatV3Tv3P4rTAUdJcUVNDTNzN1uY3ypimUf7gcZ
        keuQiTMFGq8scAUeCWZwa6qvABTht16xXm9X2bkyrhbT/R2XRQsksqZLPD7kGz7m
        MlCgqv5o8WIbvjxO0H63tlypEer1bmvzW3A4DmgY+HxHTjnItwqwESLcioX5SeZY
        aDThuTECgYEA//RouW1h30Q/1TxRvhsW8+EiREWzo3PGPGECYmzJR0sgKfOoMASB
        qcLEhjVxm6G9vr1GPyzLvaV2GyguojNozzZuNHoxeztcDVGBWXHrP3GpGm1q35ug
        jqOLfnrMHdBr+l2bgSLjyNG+dCU2D5XgE7ppfZr9mDiSZkwdI5GSFHcCgYEA6knl
        HqPxA0ASrApzw/+WN3WOlDMdKLjyEH/LvQTzdO4rpr3MreHuNk/7RljCVHwdzYNv
        w8OTqI+JpXKonH6CmWFIPVe1SMm7ZYzDqmdyS/4K2bbVTHzliYafzDqBh7ONTINX
        1JakXtk4WVe11pYJ/bdIhfLZZN2DxdqcMz1G85cCgYEA3Espz157fEQrhIXz/OEn
        8iN08LnlEOtWVSVRfhEPc9MPDcxul1VpnAjMSI67By5AN2iEi18sxD8i1eDRsjz5
        Gk9IrtX0vJGserIJ2EgaJ3LWDq7Z6zbxC5NrPiLGh2qZZNUoQA8dafxMJX7ZdrSS
        NaidnsPFPDyElJMyCSkDR6UCgYBH9KoJ3xAGj4csj4k+iSD5p4FCwvARsbumlZld
        VEfxgbSmYWSbguhGhgoGcPw+NmBw3g1VcpvHCU6dIbnnVnOF5/rn3CgxUsPbTIBL
        tbnE3SE3/I9GDpXwxwgNEWr24o5jEXPINvwEpXJI/kc6wJoQ8lmzygI6mE4AVkPi
        +M7xwQKBgQCyZEEtM1hFJj/zl59D4Jk0Dzi1XTft4QRVf50AoQKGj1JhZ0IEGL/4
        pKm6uzAF70YTqe8HoJsRfZemdUdLEcq4wtVqVSQyqvC6ALtBhn3Rx/2xd4ie6etX
        vdG2czluyDcxj7aOvV7hCFuyi8B/0uYG4lzURKwK1SpU1lme6r7Hww==
        -----END RSA PRIVATE KEY-----
        """
    static let clientRsaPk8 = """
        -----BEGIN PRIVATE KEY-----
        MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDqP0l/nxdilP80
        Kv/4IAO9P4JfrbJDGHpQt4QhozlHMeGplnFX45EUfwNdK6Jc/MBKaiTUIIbmpTMu
        DilQbnAy/hDILrhvW0lngf2BUN0uXZbdEu4o2CRUPrg8BG+MDYqc3njtIuCIHFsv
        G7Y4kW1A9W3kBztAbl8pJChjYPHIXYeELe04P+o3jrj+eaJr1fqTn9GcadpwXCqd
        itTQeA/Y1ohHIdo5sAxADZ+Sua9NsmdhgNKBPCLTrLHPCuOce6blT3x8EfFIZfwt
        J3KChe5bPXLRnRnnHWPkVUBZCgQ4Y8jfosTte4GopN8Smso0LShkB3bA1gaACwzg
        J696IQcxAgMBAAECggEAUkegnX9YS3ximARynMlCBvuD4++zKfYzIJ8VfmtC90sC
        JPt/HIwGrdhfah6ljVwKfxkBjrFOMT3d2FOJF4NzTbYIVwhyKEs8YWs7jGzHBD5D
        e6vmk9o4CI9vT0WPmPY4thk/CKyziZvMO6PUQdJzOdn7m5kequcZ7e2RcjbfNq1X
        dO/c/itMBR0lxRU0NM3M3W5jfKmKZR/uBxmR65CJMwUaryxwBR4JZnBrqq8AFOG3
        XrFeb1fZuTKuFtP9HZdFCySypks8PuQbPuYyUKCq/mjxYhu+PE7Qfre2XKkR6vVu
        a/NbcDgOaBj4fEdOOci3CrARItyKhflJ5lhoNOG5MQKBgQD/9Gi5bWHfRD/VPFG+
        Gxbz4SJERbOjc8Y8YQJibMlHSyAp86gwBIGpwsSGNXGbob2+vUY/LMu9pXYbKC6i
        M2jPNm40ejF7O1wNUYFZces/cakabWrfm6COo4t+eswd0Gv6XZuBIuPI0b50JTYP
        leATuml9mv2YOJJmTB0jkZIUdwKBgQDqSeUeo/EDQBKsCnPD/5Y3dY6UMx0ouPIQ
        f8u9BPN07iumvcyt4e42T/tGWMJUfB3Ng2/Dw5Ooj4mlcqicfoKZYUg9V7VIybtl
        jMOqZ3JL/grZttVMfOWJhp/MOoGHs41Mg1fUlqRe2ThZV7XWlgn9t0iF8tlk3YPF
        2pwzPUbzlwKBgQDcSynPXnt8RCuEhfP84SfyI3TwueUQ61ZVJVF+EQ9z0w8NzG6X
        VWmcCMxIjrsHLkA3aISLXyzEPyLV4NGyPPkaT0iu1fS8kax6sgnYSBonctYOrtnr
        NvELk2s+IsaHaplk1ShADx1p/Ewlftl2tJI1qJ2ew8U8PISUkzIJKQNHpQKBgEf0
        qgnfEAaPhyyPiT6JIPmngULC8BGxu6aVmV1UR/GBtKZhZJuC6EaGCgZw/D42YHDe
        DVVym8cJTp0huedWc4Xn+ufcKDFSw9tMgEu1ucTdITf8j0YOlfDHCA0RavbijmMR
        c8g2/ASlckj+RzrAmhDyWbPKAjqYTgBWQ+L4zvHBAoGBALJkQS0zWEUmP/OXn0Pg
        mTQPOLVdN+3hBFV/nQChAoaPUmFnQgQYv/ikqbq7MAXvRhOp7wegmxF9l6Z1R0sR
        yrjC1WpVJDKq8LoAu0GGfdHH/bF3iJ7p61e90bZzOW7INzGPto69XuEIW7KLwH/S
        5gbiXNRErArVKlTWWZ7qvsfD
        -----END PRIVATE KEY-----
        """
    static let clientEcCrt = """
        -----BEGIN CERTIFICATE-----
        MIICEjCB+6ADAgECAgkAkF21JuX7I2IwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UE
        AwwMa3ViZS10ZXN0LWNhMB4XDTI2MTExMzE3NDkzNVoXDTM2MTExMDE3NDkzNVow
        EjEQMA4GA1UEAwwHZWMtdXNlcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLmQ
        58qWKN89yiWU6yOZt37tBThnpWVFCHEq32IRh8TEcFgxq3QCTm2TiN3YjOUW6zSy
        TQ6n7qSN3xRXgomqJOqjMjAwMAkGA1UdEwQCMAAwDgYDVR0PAQH/BAQDAgWgMBMG
        A1UdJQQMMAoGCCsGAQUFBwMCMA0GCSqGSIb3DQEBCwUAA4IBAQAhZMuM/BuKERC0
        qoBUkKPFcHue30hi88fDmWc8bV7dWn7P1YHvqLneCGYMsfOdwFvHAi6RrusABiNb
        CJYILU5M74+WOO8rZaei+XearN8yDE+Ii4taeezkcq0iV+dez0XR9eKIvmcY4pOF
        Ckg6FBrWOjoMObeoYYs/XGejziArwuUGwlQLls/yuQB0LHYjOspHkDrIrqZoF54a
        8RIlSs7OHktnc8wspTUl8LHFPPHEjn0mSTcRzTfm3YroRH1k9lDLB7higx4BGgzz
        4J3OcwUpBwYgJQY1Tmeg3aNu9P3su5QcyAqEHdxgtm76+VTbbBp/BwmfNftdUudv
        /914YVY0
        -----END CERTIFICATE-----
        """
    static let clientEcKey = """
        -----BEGIN EC PRIVATE KEY-----
        MHcCAQEEIOZEFmi9Vrfa9AkPWI1e6VFnK33dhD5oHyA2pkYP2pnZoAoGCCqGSM49
        AwEHoUQDQgAEuZDnypYo3z3KJZTrI5m3fu0FOGelZUUIcSrfYhGHxMRwWDGrdAJO
        bZOI3diM5RbrNLJNDqfupI3fFFeCiaok6g==
        -----END EC PRIVATE KEY-----
        """
    static let clientEcPk8 = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg5kQWaL1Wt9r0CQ9Y
        jV7pUWcrfd2EPmgfIDamRg/amdmhRANCAAS5kOfKlijfPcollOsjmbd+7QU4Z6Vl
        RQhxKt9iEYfExHBYMat0Ak5tk4jd2IzlFus0sk0Op+6kjd8UV4KJqiTq
        -----END PRIVATE KEY-----
        """

    /// Inside the server certificate's validity, so trust tests never expire.
    static let verifyDate = ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!

    static func base64(_ pem: String) -> String { Data(pem.utf8).base64EncodedString() }
}
