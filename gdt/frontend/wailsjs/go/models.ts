export namespace config {
	
	export class Module {
	    ID: string;
	    LabelRu: string;
	    LabelEn: string;
	    DescRu: string;
	    DescEn: string;
	    Icon: string;
	    Binary: string;
	    NeedsSudo: boolean;
	    NeedsVPN: boolean;
	
	    static createFrom(source: any = {}) {
	        return new Module(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.ID = source["ID"];
	        this.LabelRu = source["LabelRu"];
	        this.LabelEn = source["LabelEn"];
	        this.DescRu = source["DescRu"];
	        this.DescEn = source["DescEn"];
	        this.Icon = source["Icon"];
	        this.Binary = source["Binary"];
	        this.NeedsSudo = source["NeedsSudo"];
	        this.NeedsVPN = source["NeedsVPN"];
	    }
	}

}

export namespace status {
	
	export class SystemStatus {
	    OSVersion: string;
	    OSBranch: string;
	    OSBuildID: string;
	    FlatpakUpdates: number;
	    OpenH264: boolean;
	    OpenH264Ver: string;
	    TunnelActive: boolean;
	    TunnelCountry: string;
	
	    static createFrom(source: any = {}) {
	        return new SystemStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.OSVersion = source["OSVersion"];
	        this.OSBranch = source["OSBranch"];
	        this.OSBuildID = source["OSBuildID"];
	        this.FlatpakUpdates = source["FlatpakUpdates"];
	        this.OpenH264 = source["OpenH264"];
	        this.OpenH264Ver = source["OpenH264Ver"];
	        this.TunnelActive = source["TunnelActive"];
	        this.TunnelCountry = source["TunnelCountry"];
	    }
	}

}

